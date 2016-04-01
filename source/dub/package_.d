/**
	Stuff with dependencies.

	Copyright: © 2012-2013 Matthias Dondorff, © 2012-2015 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Matthias Dondorff
*/
module dub.package_;

public import dub.recipe.packagerecipe;

import dub.compilers.compiler;
import dub.dependency;
import dub.description;
import dub.recipe.json;
import dub.recipe.sdl;

import dub.internal.utils;
import dub.internal.vibecompat.core.log;
import dub.internal.vibecompat.core.file;
import dub.internal.vibecompat.data.json;
import dub.internal.vibecompat.inet.url;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.range;
import std.string;
import std.typecons : Nullable;


enum PackageFormat {
	json,
	sdl
}

struct FilenameAndFormat {
	string filename;
	PackageFormat format;
}

// Supported package descriptions in decreasing order of preference.
static immutable FilenameAndFormat[] packageInfoFiles = [
	{"dub.json", PackageFormat.json},
	{"dub.sdl", PackageFormat.sdl},
	{"package.json", PackageFormat.json}
];

@property string[] packageInfoFilenames() { return packageInfoFiles.map!(f => cast(string)f.filename).array; }

@property string defaultPackageFilename() { return packageInfoFiles[0].filename; }


/**
	Represents a package, including its sub packages

	Documentation of the dub.json can be found at
	http://registry.vibed.org/package-format
*/
class Package {
	private {
		Path m_path;
		Path m_infoFile;
		PackageRecipe m_info;
		Package m_parentPackage;
	}

	static Path findPackageFile(Path path)
	{
		foreach(file; packageInfoFiles) {
			auto filename = path ~ file.filename;
			if(existsFile(filename)) return filename;
		}
		return Path.init;
	}

	this(Path root, Path recipe_file = Path.init, Package parent = null, string versionOverride = "")
	{
		import dub.recipe.io;

		if (recipe_file.empty) recipe_file = findPackageFile(root);

		enforce(!recipe_file.empty, 
			"No package file found in %s, expected one of %s"
				.format(root.toNativeString(),
					packageInfoFiles.map!(f => cast(string)f.filename).join("/")));

		m_infoFile = recipe_file;

		auto recipe = readPackageRecipe(m_infoFile, parent ? parent.name : null);

		this(recipe, root, parent, versionOverride);
	}

	this(Json package_info, Path root = Path(), Package parent = null, string versionOverride = "")
	{
		import dub.recipe.json;

		PackageRecipe recipe;
		parseJson(recipe, package_info, parent ? parent.name : null);
		this(recipe, root, parent, versionOverride);
	}

	this(PackageRecipe recipe, Path root = Path(), Package parent = null, string versionOverride = "")
	{
		if (!versionOverride.empty)
			recipe.version_ = versionOverride;

		// try to run git to determine the version of the package if no explicit version was given
		if (recipe.version_.length == 0 && !parent) {
			try recipe.version_ = determineVersionFromSCM(root);
			catch (Exception e) logDebug("Failed to determine version by SCM: %s", e.msg);

			if (recipe.version_.length == 0) {
				logDiagnostic("Note: Failed to determine version of package %s at %s. Assuming ~master.", recipe.name, this.path.toNativeString());
				// TODO: Assume unknown version here?
				// recipe.version_ = Version.UNKNOWN.toString();
				recipe.version_ = Version.MASTER.toString();
			} else logDiagnostic("Determined package version using GIT: %s %s", recipe.name, recipe.version_);
		}

		m_parentPackage = parent;
		m_path = root;
		m_path.endsWithSlash = true;

		// use the given recipe as the basis
		m_info = recipe;

		fillWithDefaults();
		simpleLint();
	}

	@property string name()
	const {
		if (m_parentPackage) return m_parentPackage.name ~ ":" ~ m_info.name;
		else return m_info.name;
	}
	@property string vers() const { return m_parentPackage ? m_parentPackage.vers : m_info.version_; }
	@property Version ver() const { return Version(this.vers); }
	@property void ver(Version ver) { assert(m_parentPackage is null); m_info.version_ = ver.toString(); }
	@property ref inout(PackageRecipe) info() inout { return m_info; }
	@property Path path() const { return m_path; }
	@property Path packageInfoFilename() const { return m_infoFile; }
	@property const(Dependency[string]) dependencies() const { return m_info.dependencies; }
	@property inout(Package) basePackage() inout { return m_parentPackage ? m_parentPackage.basePackage : this; }
	@property inout(Package) parentPackage() inout { return m_parentPackage; }
	@property inout(SubPackage)[] subPackages() inout { return m_info.subPackages; }

	@property string[] configurations()
	const {
		auto ret = appender!(string[])();
		foreach( ref config; m_info.configurations )
			ret.put(config.name);
		return ret.data;
	}

	const(Dependency[string]) getDependencies(string config)
	const {
		Dependency[string] ret;
		foreach (k, v; m_info.buildSettings.dependencies)
			ret[k] = v;
		foreach (ref conf; m_info.configurations)
			if (conf.name == config) {
				foreach (k, v; conf.buildSettings.dependencies)
					ret[k] = v;
				break;
			}
		return ret;
	}

	/** Overwrites the packge description file using the default filename with the current information.
	*/
	void storeInfo()
	{
		storeInfo(m_path);
		m_infoFile = m_path ~ defaultPackageFilename;
	}
	/// ditto
	void storeInfo(Path path)
	const {
		enforce(!ver.isUnknown, "Trying to store a package with an 'unknown' version, this is not supported.");
		auto filename = path ~ defaultPackageFilename;
		auto dstFile = openFile(filename.toNativeString(), FileMode.createTrunc);
		scope(exit) dstFile.close();
		dstFile.writePrettyJsonString(m_info.toJson());
	}

	Nullable!PackageRecipe getInternalSubPackage(string name)
	{
		foreach (ref p; m_info.subPackages)
			if (p.path.empty && p.recipe.name == name)
				return Nullable!PackageRecipe(p.recipe);
		return Nullable!PackageRecipe();
	}

	void warnOnSpecialCompilerFlags()
	{
		// warn about use of special flags
		m_info.buildSettings.warnOnSpecialCompilerFlags(m_info.name, null);
		foreach (ref config; m_info.configurations)
			config.buildSettings.warnOnSpecialCompilerFlags(m_info.name, config.name);
	}

	const(BuildSettingsTemplate) getBuildSettings(string config = null)
	const {
		if (config.length) {
			foreach (ref conf; m_info.configurations)
				if (conf.name == config)
					return conf.buildSettings;
			assert(false, "Unknown configuration: "~config);
		} else {
			return m_info.buildSettings;
		}
	}

	/// Returns all BuildSettings for the given platform and config.
	BuildSettings getBuildSettings(in BuildPlatform platform, string config)
	const {
		BuildSettings ret;
		m_info.buildSettings.getPlatformSettings(ret, platform, this.path);
		bool found = false;
		foreach(ref conf; m_info.configurations){
			if( conf.name != config ) continue;
			conf.buildSettings.getPlatformSettings(ret, platform, this.path);
			found = true;
			break;
		}
		assert(found || config is null, "Unknown configuration for "~m_info.name~": "~config);

		// construct default target name based on package name
		if( ret.targetName.empty ) ret.targetName = this.name.replace(":", "_");

		// special support for DMD style flags
		getCompiler("dmd").extractBuildOptions(ret);

		return ret;
	}

	/// Returns the combination of all build settings for all configurations and platforms
	BuildSettings getCombinedBuildSettings()
	const {
		BuildSettings ret;
		m_info.buildSettings.getPlatformSettings(ret, BuildPlatform.any, this.path);
		foreach(ref conf; m_info.configurations)
			conf.buildSettings.getPlatformSettings(ret, BuildPlatform.any, this.path);

		// construct default target name based on package name
		if (ret.targetName.empty) ret.targetName = this.name.replace(":", "_");

		// special support for DMD style flags
		getCompiler("dmd").extractBuildOptions(ret);

		return ret;
	}

	void addBuildTypeSettings(ref BuildSettings settings, in BuildPlatform platform, string build_type)
	const {
		if (build_type == "$DFLAGS") {
			import std.process;
			string dflags = environment.get("DFLAGS");
			settings.addDFlags(dflags.split());
			return;
		}

		if (auto pbt = build_type in m_info.buildTypes) {
			logDiagnostic("Using custom build type '%s'.", build_type);
			pbt.getPlatformSettings(settings, platform, this.path);
		} else {
			with(BuildOption) switch (build_type) {
				default: throw new Exception(format("Unknown build type for %s: '%s'", this.name, build_type));
				case "plain": break;
				case "debug": settings.addOptions(debugMode, debugInfo); break;
				case "release": settings.addOptions(releaseMode, optimize, inline); break;
				case "release-debug": settings.addOptions(releaseMode, optimize, inline, debugInfo); break;
				case "release-nobounds": settings.addOptions(releaseMode, optimize, inline, noBoundsCheck); break;
				case "unittest": settings.addOptions(unittests, debugMode, debugInfo); break;
				case "docs": settings.addOptions(syntaxOnly, _docs); break;
				case "ddox": settings.addOptions(syntaxOnly,  _ddox); break;
				case "profile": settings.addOptions(profile, optimize, inline, debugInfo); break;
				case "profile-gc": settings.addOptions(profileGC, debugInfo); break;
				case "cov": settings.addOptions(coverage, debugInfo); break;
				case "unittest-cov": settings.addOptions(unittests, coverage, debugMode, debugInfo); break;
			}
		}
	}

	string getSubConfiguration(string config, in Package dependency, in BuildPlatform platform)
	const {
		bool found = false;
		foreach(ref c; m_info.configurations){
			if( c.name == config ){
				if( auto pv = dependency.name in c.buildSettings.subConfigurations ) return *pv;
				found = true;
				break;
			}
		}
		assert(found || config is null, "Invalid configuration \""~config~"\" for "~this.name);
		if( auto pv = dependency.name in m_info.buildSettings.subConfigurations ) return *pv;
		return null;
	}

	/// Returns the default configuration to build for the given platform
	string getDefaultConfiguration(in BuildPlatform platform, bool allow_non_library = false)
	const {
		foreach (ref conf; m_info.configurations) {
			if (!conf.matchesPlatform(platform)) continue;
			if (!allow_non_library && conf.buildSettings.targetType == TargetType.executable) continue;
			return conf.name;
		}
		return null;
	}

	/// Returns a list of configurations suitable for the given platform
	string[] getPlatformConfigurations(in BuildPlatform platform, bool is_main_package = false)
	const {
		auto ret = appender!(string[]);
		foreach(ref conf; m_info.configurations){
			if (!conf.matchesPlatform(platform)) continue;
			if (!is_main_package && conf.buildSettings.targetType == TargetType.executable) continue;
			ret ~= conf.name;
		}
		if (ret.data.length == 0) ret.put(null);
		return ret.data;
	}

	/// Human readable information of this package and its dependencies.
	string generateInfoString() const {
		string s;
		s ~= m_info.name ~ ", version '" ~ m_info.version_ ~ "'";
		s ~= "\n  Dependencies:";
		foreach(string p, ref const Dependency v; m_info.dependencies)
			s ~= "\n    " ~ p ~ ", version '" ~ v.toString() ~ "'";
		return s;
	}

	bool hasDependency(string depname, string config)
	const {
		if (depname in m_info.buildSettings.dependencies) return true;
		foreach (ref c; m_info.configurations)
			if ((config.empty || c.name == config) && depname in c.buildSettings.dependencies)
				return true;
		return false;
	}

	/** Returns a description of the package for use in IDEs or build tools.
	*/
	PackageDescription describe(BuildPlatform platform, string config)
	const {
		PackageDescription ret;
		ret.configuration = config;
		ret.path = m_path.toNativeString();
		ret.name = this.name;
		ret.version_ = this.ver;
		ret.description = m_info.description;
		ret.homepage = m_info.homepage;
		ret.authors = m_info.authors.dup;
		ret.copyright = m_info.copyright;
		ret.license = m_info.license;
		ret.dependencies = getDependencies(config).keys;

		// save build settings
		BuildSettings bs = getBuildSettings(platform, config);
		BuildSettings allbs = getCombinedBuildSettings();

		ret.targetType = bs.targetType;
		ret.targetPath = bs.targetPath;
		ret.targetName = bs.targetName;
		if (ret.targetType != TargetType.none)
			ret.targetFileName = getTargetFileName(bs, platform);
		ret.workingDirectory = bs.workingDirectory;
		ret.mainSourceFile = bs.mainSourceFile;
		ret.dflags = bs.dflags;
		ret.lflags = bs.lflags;
		ret.libs = bs.libs;
		ret.copyFiles = bs.copyFiles;
		ret.versions = bs.versions;
		ret.debugVersions = bs.debugVersions;
		ret.importPaths = bs.importPaths;
		ret.stringImportPaths = bs.stringImportPaths;
		ret.preGenerateCommands = bs.preGenerateCommands;
		ret.postGenerateCommands = bs.postGenerateCommands;
		ret.preBuildCommands = bs.preBuildCommands;
		ret.postBuildCommands = bs.postBuildCommands;

		// prettify build requirements output
		for (int i = 1; i <= BuildRequirement.max; i <<= 1)
			if (bs.requirements & cast(BuildRequirement)i)
				ret.buildRequirements ~= cast(BuildRequirement)i;

		// prettify options output
		for (int i = 1; i <= BuildOption.max; i <<= 1)
			if (bs.options & cast(BuildOption)i)
				ret.options ~= cast(BuildOption)i;

		// collect all possible source files and determine their types
		SourceFileRole[string] sourceFileTypes;
		foreach (f; allbs.stringImportFiles) sourceFileTypes[f] = SourceFileRole.unusedStringImport;
		foreach (f; allbs.importFiles) sourceFileTypes[f] = SourceFileRole.unusedImport;
		foreach (f; allbs.sourceFiles) sourceFileTypes[f] = SourceFileRole.unusedSource;
		foreach (f; bs.stringImportFiles) sourceFileTypes[f] = SourceFileRole.stringImport;
		foreach (f; bs.importFiles) sourceFileTypes[f] = SourceFileRole.import_;
		foreach (f; bs.sourceFiles) sourceFileTypes[f] = SourceFileRole.source;
		foreach (f; sourceFileTypes.byKey.array.sort()) {
			SourceFileDescription sf;
			sf.path = f;
			sf.type = sourceFileTypes[f];
			ret.files ~= sf;
		}

		return ret;
	}
	// ditto
	deprecated void describe(ref Json dst, BuildPlatform platform, string config)
	{
		auto res = describe(platform, config);
		foreach (string key, value; res.serializeToJson())
			dst[key] = value;
	}

	private void fillWithDefaults()
	{
		auto bs = &m_info.buildSettings;

		// check for default string import folders
		if ("" !in bs.stringImportPaths) {
			foreach(defvf; ["views"]){
				if( existsFile(m_path ~ defvf) )
					bs.stringImportPaths[""] ~= defvf;
			}
		}

		// check for default source folders
		immutable hasSP = ("" in bs.sourcePaths) !is null;
		immutable hasIP = ("" in bs.importPaths) !is null;
		if (!hasSP || !hasIP) {
			foreach (defsf; ["source/", "src/"]) {
				if (existsFile(m_path ~ defsf)) {
					if (!hasSP) bs.sourcePaths[""] ~= defsf;
					if (!hasIP) bs.importPaths[""] ~= defsf;
				}
			}
		}

		// check for default app_main
		string app_main_file;
		auto pkg_name = m_info.name.length ? m_info.name : "unknown";
		foreach(sf; bs.sourcePaths.get("", null)){
			auto p = m_path ~ sf;
			if( !existsFile(p) ) continue;
			foreach(fil; ["app.d", "main.d", pkg_name ~ "/main.d", pkg_name ~ "/" ~ "app.d"]){
				if( existsFile(p ~ fil) ) {
					app_main_file = (Path(sf) ~ fil).toNativeString();
					break;
				}
			}
		}

		// generate default configurations if none are defined
		if (m_info.configurations.length == 0) {
			if (bs.targetType == TargetType.executable) {
				BuildSettingsTemplate app_settings;
				app_settings.targetType = TargetType.executable;
				if (bs.mainSourceFile.empty) app_settings.mainSourceFile = app_main_file;
				m_info.configurations ~= ConfigurationInfo("application", app_settings);
			} else if (bs.targetType != TargetType.none) {
				BuildSettingsTemplate lib_settings;
				lib_settings.targetType = bs.targetType == TargetType.autodetect ? TargetType.library : bs.targetType;

				if (bs.targetType == TargetType.autodetect) {
					if (app_main_file.length) {
						lib_settings.excludedSourceFiles[""] ~= app_main_file;

						BuildSettingsTemplate app_settings;
						app_settings.targetType = TargetType.executable;
						app_settings.mainSourceFile = app_main_file;
						m_info.configurations ~= ConfigurationInfo("application", app_settings);
					}
				}

				m_info.configurations ~= ConfigurationInfo("library", lib_settings);
			}
		}
	}

	private void simpleLint() const {
		if (m_parentPackage) {
			if (m_parentPackage.path != path) {
				if (info.license.length && info.license != m_parentPackage.info.license)
					logWarn("License in subpackage %s is different than it's parent package, this is discouraged.", name);
			}
		}
		if (name.empty) logWarn("The package in %s has no name.", path);
	}
}

private string determineVersionFromSCM(Path path)
{
	// On Windows, which is slow at running external processes,
	// cache the version numbers that are determined using
	// GIT to speed up the initialization phase.
	version (Windows) {
		import std.file : exists, readText;

		// quickly determine head commit without invoking GIT
		string head_commit;
		auto hpath = (path ~ ".git/HEAD").toNativeString();
		if (exists(hpath)) {
			auto head_ref = readText(hpath).strip();
			if (head_ref.startsWith("ref: ")) {
				auto rpath = (path ~ (".git/"~head_ref[5 .. $])).toNativeString();
				if (exists(rpath))
					head_commit = readText(rpath).strip();
			}
		}

		// return the last determined version for that commit
		// not that this is not always correct, most notably when
		// a tag gets added/removed/changed and changes the outcome
		// of the full version detection computation
		auto vcachepath = path ~ ".dub/version.json";
		if (existsFile(vcachepath)) {
			auto ver = jsonFromFile(vcachepath);
			if (head_commit == ver["commit"].opt!string)
				return ver["version"].get!string;
		}
	}

	// if no cache file or the HEAD commit changed, perform full detection
	auto ret = determineVersionWithGIT(path);

	version (Windows) {
		// update version cache file
		if (head_commit.length) {
			if (!existsFile(path ~".dub")) createDirectory(path ~ ".dub");
			atomicWriteJsonFile(vcachepath, Json(["commit": Json(head_commit), "version": Json(ret)]));
		}
	}

	return ret;
}

// determines the version of a package that is stored in a GIT working copy
// by invoking the "git" executable
private string determineVersionWithGIT(Path path)
{
	import std.process;
	import dub.semver;

	auto git_dir = path ~ ".git";
	if (!existsFile(git_dir) || !isDir(git_dir.toNativeString)) return null;
	auto git_dir_param = "--git-dir=" ~ git_dir.toNativeString();

	static string exec(scope string[] params...) {
		auto ret = executeShell(escapeShellCommand(params));
		if (ret.status == 0) return ret.output.strip;
		logDebug("'%s' failed with exit code %s: %s", params.join(" "), ret.status, ret.output.strip);
		return null;
	}

	auto tag = exec("git", git_dir_param, "describe", "--long", "--tags");
	if (tag !is null) {
		auto parts = tag.split("-");
		auto commit = parts[$-1];
		auto num = parts[$-2].to!int;
		tag = parts[0 .. $-2].join("-");
		if (tag.startsWith("v") && isValidVersion(tag[1 .. $])) {
			if (num == 0) return tag[1 .. $];
			else if (tag.canFind("+")) return format("%s.commit.%s.%s", tag[1 .. $], num, commit);
			else return format("%s+commit.%s.%s", tag[1 .. $], num, commit);
		}
	}

	auto branch = exec("git", git_dir_param, "rev-parse", "--abbrev-ref", "HEAD");
	if (branch !is null) {
		if (branch != "HEAD") return "~" ~ branch;
	}

	return null;
}

bool isRecursiveInvocation(string pack)
{
	import std.process : environment;

	return environment
        .get("DUB_PACKAGES_USED", "")
        .splitter(",")
        .canFind(pack);
}

void storeRecursiveInvokations(string[string] env, string[] packs)
{
	import std.process : environment;

    env["DUB_PACKAGES_USED"] = environment
        .get("DUB_PACKAGES_USED", "")
        .splitter(",")
        .chain(packs)
        .join(",");
}
