/**
	A package manager.

	Copyright: © 2012-2013 Matthias Dondorff
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Matthias Dondorff, Sönke Ludwig
*/
module dub.dub;

import dub.compilers.compiler;
import dub.dependency;
import dub.dependencyresolver;
import dub.internal.utils;
import dub.internal.vibecompat.core.file;
import dub.internal.vibecompat.core.log;
import dub.internal.vibecompat.data.json;
import dub.internal.vibecompat.inet.url;
import dub.package_;
import dub.packagemanager;
import dub.packagesupplier;
import dub.project;
import dub.generators.generator;
import dub.init;


// todo: cleanup imports.
import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.exception;
import std.file;
import std.process;
import std.string;
import std.typecons;
import std.zip;
import std.encoding : sanitize;

// Workaround for libcurl liker errors when building with LDC
version (LDC) pragma(lib, "curl");

// Set output path and options for coverage reports
version (DigitalMars) version (D_Coverage) static if (__VERSION__ >= 2068)
{
	shared static this()
	{
		import core.runtime, std.file, std.path, std.stdio;
		dmd_coverSetMerge(true);
		auto path = buildPath(dirName(thisExePath()), "../cov");
		if (!path.exists)
			mkdir(path);
		dmd_coverDestPath(path);
	}
}

enum defaultRegistryURL = "http://code.dlang.org/";

/// The default supplier for packages, which is the registry
/// hosted by code.dlang.org.
PackageSupplier[] defaultPackageSuppliers()
{
	logDiagnostic("Using dub registry url '%s'", defaultRegistryURL);
	return [new RegistryPackageSupplier(URL(defaultRegistryURL))];
}

/// Option flags for fetch
enum FetchOptions
{
	none = 0,
	forceBranchUpgrade = 1<<0,
	usePrerelease = 1<<1,
	forceRemove = 1<<2,
	printOnly = 1<<3,
}

/// The Dub class helps in getting the applications
/// dependencies up and running. An instance manages one application.
class Dub {
	private {
		bool m_dryRun = false;
		PackageManager m_packageManager;
		PackageSupplier[] m_packageSuppliers;
		Path m_rootPath;
		Path m_tempPath;
		Path m_userDubPath, m_systemDubPath;
		Json m_systemConfig, m_userConfig;
		Path m_projectPath;
		Project m_project;
		Path m_overrideSearchPath;
	}

	/// Initiales the package manager for the vibe application
	/// under root.
	this(PackageSupplier[] additional_package_suppliers = null, string root_path = ".", SkipRegistry skip_registry = SkipRegistry.none)
	{
		m_rootPath = Path(root_path);
		if (!m_rootPath.absolute) m_rootPath = Path(getcwd()) ~ m_rootPath;

		init();

		PackageSupplier[] ps = additional_package_suppliers;

		if (skip_registry < SkipRegistry.all) {
			if (auto pp = "registryUrls" in m_userConfig)
				ps ~= deserializeJson!(string[])(*pp)
					.map!(url => cast(PackageSupplier)new RegistryPackageSupplier(URL(url)))
					.array;
		}

		if (skip_registry < SkipRegistry.all) {
			if (auto pp = "registryUrls" in m_systemConfig)
				ps ~= deserializeJson!(string[])(*pp)
					.map!(url => cast(PackageSupplier)new RegistryPackageSupplier(URL(url)))
					.array;
		}

		if (skip_registry < SkipRegistry.standard)
			ps ~= defaultPackageSuppliers();

		m_packageSuppliers = ps;
		m_packageManager = new PackageManager(m_userDubPath, m_systemDubPath);
		updatePackageSearchPath();
	}

	/// Initializes DUB with only a single search path
	this(Path override_path)
	{
		init();
		m_overrideSearchPath = override_path;
		m_packageManager = new PackageManager(Path(), Path(), false);
		updatePackageSearchPath();
	}

	private void init()
	{
		version(Windows){
			m_systemDubPath = Path(environment.get("ProgramData")) ~ "dub/";
			m_userDubPath = Path(environment.get("APPDATA")) ~ "dub/";
			m_tempPath = Path(environment.get("TEMP"));
		} else version(Posix){
			m_systemDubPath = Path("/var/lib/dub/");
			m_userDubPath = Path(environment.get("HOME")) ~ ".dub/";
			if(!m_userDubPath.absolute)
				m_userDubPath = Path(getcwd()) ~ m_userDubPath;
			m_tempPath = Path("/tmp");
		}

		m_userConfig = jsonFromFile(m_userDubPath ~ "settings.json", true);
		m_systemConfig = jsonFromFile(m_systemDubPath ~ "settings.json", true);
	}

	@property void dryRun(bool v) { m_dryRun = v; }

	/** Returns the root path (usually the current working directory).
	*/
	@property Path rootPath() const { return m_rootPath; }
	/// ditto
	@property void rootPath(Path root_path)
	{
		m_rootPath = root_path;
		if (!m_rootPath.absolute) m_rootPath = Path(getcwd()) ~ m_rootPath;
	}

	/// Returns the name listed in the dub.json of the current
	/// application.
	@property string projectName() const { return m_project.name; }

	@property Path projectPath() const { return m_projectPath; }

	@property string[] configurations() const { return m_project.configurations; }

	@property inout(PackageManager) packageManager() inout { return m_packageManager; }

	@property inout(Project) project() inout { return m_project; }

	/// Returns the default compiler binary to use for building D code.
	@property string defaultCompiler()
	const {
		if (auto pv = "defaultCompiler" in m_userConfig)
			if (pv.type == Json.Type.string)
				return pv.get!string;

		if (auto pv = "defaultCompiler" in m_systemConfig)
			if (pv.type == Json.Type.string)
				return pv.get!string;

		return .defaultCompiler();
	}

	deprecated void shutdown() {}
	deprecated void cleanCaches() {}

	/// Loads the package from the current working directory as the main
	/// project package.
	void loadPackageFromCwd()
	{
		loadPackage(m_rootPath);
	}

	/// Loads the package from the specified path as the main project package.
	void loadPackage(Path path)
	{
		m_projectPath = path;
		updatePackageSearchPath();
		m_project = new Project(m_packageManager, m_projectPath);
	}

	/// Loads a specific package as the main project package (can be a sub package)
	void loadPackage(Package pack)
	{
		m_projectPath = pack.path;
		updatePackageSearchPath();
		m_project = new Project(m_packageManager, pack);
	}

	void overrideSearchPath(Path path)
	{
		if (!path.absolute) path = Path(getcwd()) ~ path;
		m_overrideSearchPath = path;
		updatePackageSearchPath();
	}

	string getDefaultConfiguration(BuildPlatform platform, bool allow_non_library_configs = true) const { return m_project.getDefaultConfiguration(platform, allow_non_library_configs); }

	void upgrade(UpgradeOptions options)
	{
		// clear non-existent version selections
		if (!(options & UpgradeOptions.upgrade)) {
			next_pack:
			foreach (p; m_project.selections.selectedPackages) {
				auto dep = m_project.selections.getSelectedVersion(p);
				if (!dep.path.empty) {
					auto path = dep.path;
					if (!path.absolute) path = this.rootPath ~ path;
					try if (m_packageManager.getOrLoadPackage(path)) continue;
					catch (Exception e) { logDebug("Failed to load path based selection: %s", e.toString().sanitize); }
				} else {
					if (m_packageManager.getPackage(p, dep.version_)) continue;
					foreach (ps; m_packageSuppliers) {
						try {
							auto versions = ps.getVersions(p);
							if (versions.canFind!(v => dep.matches(v)))
								continue next_pack;
						} catch (Exception e) {
							logDiagnostic("Error querying versions for %s, %s: %s", p, ps.description, e.msg);
							logDebug("Full error: %s", e.toString().sanitize());
						}
					}
				}

				logWarn("Selected package %s %s doesn't exist. Using latest matching version instead.", p, dep);
				m_project.selections.deselectVersion(p);
			}
		}

		Dependency[string] versions;
		if ((options & UpgradeOptions.useCachedResult) && m_project.isUpgradeCacheUpToDate()) {
			logDiagnostic("Using cached upgrade results...");
			versions = m_project.getUpgradeCache();
		} else {
			auto resolver = new DependencyVersionResolver(this, options);
			versions = resolver.resolve(m_project.rootPackage, m_project.selections);
			if (options & UpgradeOptions.useCachedResult) {
				logDiagnostic("Caching upgrade results...");
				m_project.setUpgradeCache(versions);
			}
		}

		if (options & UpgradeOptions.printUpgradesOnly) {
			bool any = false;
			string rootbasename = getBasePackageName(m_project.rootPackage.name);

			foreach (p, ver; versions) {
				if (!ver.path.empty) continue;

				auto basename = getBasePackageName(p);
				if (basename == rootbasename) continue;

				if (!m_project.selections.hasSelectedVersion(basename)) {
					logInfo("Package %s can be installed with version %s.",
						basename, ver);
					any = true;
					continue;
				}
				auto sver = m_project.selections.getSelectedVersion(basename);
				if (!sver.path.empty) continue;
				if (ver.version_ <= sver.version_) continue;
				logInfo("Package %s can be upgraded from %s to %s.",
					basename, sver, ver);
				any = true;
			}
			if (any) logInfo("Use \"dub upgrade\" to perform those changes.");
			return;
		}

		foreach (p; versions.byKey) {
			auto ver = versions[p]; // Workaround for DMD 2.070.0 AA issue (crashes in aaApply2 if iterating by key+value)
			assert(!p.canFind(":"), "Resolved packages contain a sub package!?: "~p);
			Package pack;
			if (!ver.path.empty) {
				try pack = m_packageManager.getOrLoadPackage(ver.path);
				catch (Exception e) {
					logDebug("Failed to load path based selection: %s", e.toString().sanitize);
					continue;
				}
			} else {
				pack = m_packageManager.getBestPackage(p, ver);
				if (pack && m_packageManager.isManagedPackage(pack)
					&& ver.version_.isBranch && (options & UpgradeOptions.upgrade) != 0)
				{
					// TODO: only re-install if there is actually a new commit available
					logInfo("Re-installing branch based dependency %s %s", p, ver.toString());
					m_packageManager.remove(pack, (options & UpgradeOptions.forceRemove) != 0);
					pack = null;
				}
			}

			FetchOptions fetchOpts;
			fetchOpts |= (options & UpgradeOptions.preRelease) != 0 ? FetchOptions.usePrerelease : FetchOptions.none;
			fetchOpts |= (options & UpgradeOptions.forceRemove) != 0 ? FetchOptions.forceRemove : FetchOptions.none;
			if (!pack) fetch(p, ver, defaultPlacementLocation, fetchOpts, "getting selected version");
			if ((options & UpgradeOptions.select) && p != m_project.rootPackage.name) {
				if (ver.path.empty) m_project.selections.selectVersion(p, ver.version_);
				else {
					Path relpath = ver.path;
					if (relpath.absolute) relpath = relpath.relativeTo(m_project.rootPackage.path);
					m_project.selections.selectVersion(p, relpath);
				}
			}
		}

		m_project.reinit();

		if (options & UpgradeOptions.select)
			m_project.saveSelections();
	}

	/// Generate project files for a specified IDE.
	/// Any existing project files will be overridden.
	void generateProject(string ide, GeneratorSettings settings) {
		auto generator = createProjectGenerator(ide, m_project);
		if (m_dryRun) return; // TODO: pass m_dryRun to the generator
		generator.generate(settings);
	}

	/// Executes tests on the current project. Throws an exception, if
	/// unittests failed.
	void testProject(GeneratorSettings settings, string config, Path custom_main_file)
	{
		if (custom_main_file.length && !custom_main_file.absolute) custom_main_file = getWorkingDirectory() ~ custom_main_file;

		if (config.length == 0) {
			// if a custom main file was given, favor the first library configuration, so that it can be applied
			if (custom_main_file.length) config = m_project.getDefaultConfiguration(settings.platform, false);
			// else look for a "unittest" configuration
			if (!config.length && m_project.rootPackage.configurations.canFind("unittest")) config = "unittest";
			// if not found, fall back to the first "library" configuration
			if (!config.length) config = m_project.getDefaultConfiguration(settings.platform, false);
			// if still nothing found, use the first executable configuration
			if (!config.length) config = m_project.getDefaultConfiguration(settings.platform, true);
		}

		auto generator = createProjectGenerator("build", m_project);

		auto test_config = format("__test__%s__", config);

		BuildSettings lbuildsettings = settings.buildSettings;
		m_project.addBuildSettings(lbuildsettings, settings.platform, config, null, true);
		if (lbuildsettings.targetType == TargetType.none) {
			logInfo(`Configuration '%s' has target type "none". Skipping test.`, config);
			return;
		}

		if (lbuildsettings.targetType == TargetType.executable) {
			if (config == "unittest") logInfo("Running custom 'unittest' configuration.", config);
			else logInfo(`Configuration '%s' does not output a library. Falling back to "dub -b unittest -c %s".`, config, config);
			if (!custom_main_file.empty) logWarn("Ignoring custom main file.");
			settings.config = config;
		} else if (lbuildsettings.sourceFiles.empty) {
			logInfo(`No source files found in configuration '%s'. Falling back to "dub -b unittest".`, config);
			if (!custom_main_file.empty) logWarn("Ignoring custom main file.");
			settings.config = m_project.getDefaultConfiguration(settings.platform);
		} else {
			logInfo(`Generating test runner configuration '%s' for '%s' (%s).`, test_config, config, lbuildsettings.targetType);

			BuildSettingsTemplate tcinfo = m_project.rootPackage.info.getConfiguration(config).buildSettings;
			tcinfo.targetType = TargetType.executable;
			tcinfo.targetName = test_config;
			tcinfo.versions[""] ~= "VibeCustomMain"; // HACK for vibe.d's legacy main() behavior
			string custommodname;
			if (custom_main_file.length) {
				import std.path;
				tcinfo.sourceFiles[""] ~= custom_main_file.relativeTo(m_project.rootPackage.path).toNativeString();
				tcinfo.importPaths[""] ~= custom_main_file.parentPath.toNativeString();
				custommodname = custom_main_file.head.toString().baseName(".d");
			}

			string[] import_modules;
			foreach (file; lbuildsettings.sourceFiles) {
				if (file.endsWith(".d") && Path(file).head.toString() != "package.d")
					import_modules ~= lbuildsettings.determineModuleName(Path(file), m_project.rootPackage.path);
			}

			// generate main file
			Path mainfile = getTempFile("dub_test_root", ".d");
			tcinfo.sourceFiles[""] ~= mainfile.toNativeString();
			tcinfo.mainSourceFile = mainfile.toNativeString();
			if (!m_dryRun) {
				auto fil = openFile(mainfile, FileMode.createTrunc);
				scope(exit) fil.close();
				fil.write("module dub_test_root;\n");
				fil.write("import std.typetuple;\n");
				foreach (mod; import_modules) fil.write(format("static import %s;\n", mod));
				fil.write("alias allModules = TypeTuple!(");
				foreach (i, mod; import_modules) {
					if (i > 0) fil.write(", ");
					fil.write(mod);
				}
				fil.write(");\n");
				if (custommodname.length) {
					fil.write(format("import %s;\n", custommodname));
				} else {
					fil.write(q{
						import std.stdio;
						import core.runtime;

						void main() { writeln("All unit tests have been run successfully."); }
						shared static this() {
							version (Have_tested) {
								import tested;
								import core.runtime;
								import std.exception;
								Runtime.moduleUnitTester = () => true;
								//runUnitTests!app(new JsonTestResultWriter("results.json"));
								enforce(runUnitTests!allModules(new ConsoleTestResultWriter), "Unit tests failed.");
							}
						}
					});
				}
			}
			m_project.rootPackage.info.configurations ~= ConfigurationInfo(test_config, tcinfo);
			m_project = new Project(m_packageManager, m_project.rootPackage);

			settings.config = test_config;
		}

		generator.generate(settings);
	}

	/// Outputs a JSON description of the project, including its dependencies.
	deprecated void describeProject(BuildPlatform platform, Compiler compiler, string config)
	{
		import std.stdio;
		auto desc = m_project.describe(platform, compiler, config);
		writeln(desc.serializeToPrettyJson());
	}

	void listImportPaths(BuildPlatform platform, Compiler compiler, string config, string buildType, bool nullDelim)
	{
		import std.stdio;

		foreach(path; m_project.listImportPaths(platform, compiler, config, buildType, nullDelim)) {
			writeln(path);
		}
	}

	void listStringImportPaths(BuildPlatform platform, Compiler compiler, string config, string buildType, bool nullDelim)
	{
		import std.stdio;

		foreach(path; m_project.listStringImportPaths(platform, compiler, config, buildType, nullDelim)) {
			writeln(path);
		}
	}

	void listProjectData(BuildPlatform platform, string config, string buildType,
		string[] requestedData, Compiler formattingCompiler, bool nullDelim)
	{
		import std.stdio;
		import std.ascii : newline;

		// Split comma-separated lists
		string[] requestedDataSplit =
			requestedData
			.map!(a => a.splitter(",").map!strip)
			.joiner()
			.array();

		auto data = m_project.listBuildSettings(platform, config, buildType,
			requestedDataSplit, formattingCompiler, nullDelim);

		write( data.joiner(nullDelim? "\0" : newline) );
		if(!nullDelim)
			writeln();
	}

	/// Cleans intermediate/cache files of the given package
	void cleanPackage(Path path)
	{
		logInfo("Cleaning package at %s...", path.toNativeString());
		enforce(!Package.findPackageFile(path).empty, "No package found.", path.toNativeString());

		// TODO: clear target files and copy files

		if (existsFile(path ~ ".dub/build")) rmdirRecurse((path ~ ".dub/build").toNativeString());
		if (existsFile(path ~ ".dub/obj")) rmdirRecurse((path ~ ".dub/obj").toNativeString());
	}


	/// Returns all cached packages as a "packageId" = "version" associative array
	string[string] cachedPackages() const { return m_project.cachedPackagesIDs; }

	/// Fetches the package matching the dependency and places it in the specified location.
	Package fetch(string packageId, const Dependency dep, PlacementLocation location, FetchOptions options, string reason = "")
	{
		Json pinfo;
		PackageSupplier supplier;
		foreach(ps; m_packageSuppliers){
			try {
				pinfo = ps.getPackageDescription(packageId, dep, (options & FetchOptions.usePrerelease) != 0);
				supplier = ps;
				break;
			} catch(Exception e) {
				logDiagnostic("Package %s not found for %s: %s", packageId, ps.description, e.msg);
				logDebug("Full error: %s", e.toString().sanitize());
			}
		}
		enforce(pinfo.type != Json.Type.undefined, "No package "~packageId~" was found matching the dependency "~dep.toString());
		string ver = pinfo["version"].get!string;

		Path placement;
		final switch (location) {
			case PlacementLocation.local: placement = m_rootPath; break;
			case PlacementLocation.user: placement = m_userDubPath ~ "packages/"; break;
			case PlacementLocation.system: placement = m_systemDubPath ~ "packages/"; break;
		}

		// always upgrade branch based versions - TODO: actually check if there is a new commit available
		Package existing;
		try existing = m_packageManager.getPackage(packageId, ver, placement);
		catch (Exception e) {
			logWarn("Failed to load existing package %s: %s", ver, e.msg);
			logDiagnostic("Full error: %s", e.toString().sanitize);
		}

		if (options & FetchOptions.printOnly) {
			if (existing && existing.vers != ver)
				logInfo("A new version for %s is available (%s -> %s). Run \"dub upgrade %s\" to switch.",
					packageId, existing.vers, ver, packageId);
			return null;
		}

		if (existing) {
			if (!ver.startsWith("~") || !(options & FetchOptions.forceBranchUpgrade) || location == PlacementLocation.local) {
				// TODO: support git working trees by performing a "git pull" instead of this
				logDiagnostic("Package %s %s (%s) is already present with the latest version, skipping upgrade.",
					packageId, ver, placement);
				return existing;
			} else {
				logInfo("Removing %s %s to prepare replacement with a new version.", packageId, ver);
				if (!m_dryRun) m_packageManager.remove(existing, (options & FetchOptions.forceRemove) != 0);
			}
		}

		if (reason.length) logInfo("Fetching %s %s (%s)...", packageId, ver, reason);
		else logInfo("Fetching %s %s...", packageId, ver);
		if (m_dryRun) return null;

		logDiagnostic("Acquiring package zip file");

		auto clean_package_version = ver[ver.startsWith("~") ? 1 : 0 .. $];
		clean_package_version = clean_package_version.replace("+", "_"); // + has special meaning for Optlink
		if (!placement.existsFile())
			mkdirRecurse(placement.toNativeString());
		Path dstpath = placement ~ (packageId ~ "-" ~ clean_package_version);
		if (!dstpath.existsFile())
			mkdirRecurse(dstpath.toNativeString());

		// Support libraries typically used with git submodules like ae.
		// Such libraries need to have ".." as import path but this can create
		// import path leakage.
		dstpath = dstpath ~ packageId;

		auto lock = lockFile(dstpath.toNativeString() ~ ".lock", 30.seconds); // possibly wait for other dub instance
		if (dstpath.existsFile())
		{
			m_packageManager.refresh(false);
			return m_packageManager.getPackage(packageId, ver, dstpath);
		}

		auto path = getTempFile(packageId, ".zip");
		supplier.retrievePackage(path, packageId, dep, (options & FetchOptions.usePrerelease) != 0); // Q: continue on fail?
		scope(exit) std.file.remove(path.toNativeString());

		logInfo("Placing %s %s to %s...", packageId, ver, placement.toNativeString());
		return m_packageManager.storeFetchedPackage(path, pinfo, dstpath);
	}

	/// Removes a given package from the list of present/cached modules.
	/// @removeFromApplication: if true, this will also remove an entry in the
	/// list of dependencies in the application's dub.json
	void remove(in Package pack, bool force_remove)
	{
		logInfo("Removing %s in %s", pack.name, pack.path.toNativeString());
		if (!m_dryRun) m_packageManager.remove(pack, force_remove);
	}

	/// @see remove(string, string, RemoveLocation)
	enum RemoveVersionWildcard = "*";

	/// This will remove a given package with a specified version from the
	/// location.
	/// It will remove at most one package, unless @param version_ is
	/// specified as wildcard "*".
	/// @param package_id Package to be removed
	/// @param version_ Identifying a version or a wild card. An empty string
	/// may be passed into. In this case the package will be removed from the
	/// location, if there is only one version retrieved. This will throw an
	/// exception, if there are multiple versions retrieved.
	/// Note: as wildcard string only RemoveVersionWildcard ("*") is supported.
	/// @param location_
	void remove(string package_id, string version_, PlacementLocation location_, bool force_remove)
	{
		enforce(!package_id.empty);
		if (location_ == PlacementLocation.local) {
			logInfo("To remove a locally placed package, make sure you don't have any data"
					~ "\nleft in it's directory and then simply remove the whole directory.");
			throw new Exception("dub cannot remove locally installed packages.");
		}

		Package[] packages;
		const bool wildcardOrEmpty = version_ == RemoveVersionWildcard || version_.empty;

		// Retrieve packages to be removed.
		foreach(pack; m_packageManager.getPackageIterator(package_id))
			if ((wildcardOrEmpty || pack.vers == version_) && m_packageManager.isManagedPackage(pack))
				packages ~= pack;

		// Check validity of packages to be removed.
		if(packages.empty) {
			throw new Exception("Cannot find package to remove. ("
				~ "id: '" ~ package_id ~ "', version: '" ~ version_ ~ "', location: '" ~ to!string(location_) ~ "'"
				~ ")");
		}
		if(version_.empty && packages.length > 1) {
			logError("Cannot remove package '" ~ package_id ~ "', there are multiple possibilities at location\n"
				~ "'" ~ to!string(location_) ~ "'.");
			logError("Available versions:");
			foreach(pack; packages)
				logError("  %s", pack.vers);
			throw new Exception("Please specify a individual version using --version=... or use the"
				~ " wildcard --version=" ~ RemoveVersionWildcard ~ " to remove all versions.");
		}

		logDebug("Removing %s packages.", packages.length);
		foreach(pack; packages) {
			try {
				remove(pack, force_remove);
				logInfo("Removed %s, version %s.", package_id, pack.vers);
			} catch (Exception e) {
				logError("Failed to remove %s %s: %s", package_id, pack.vers, e.msg);
				logInfo("Continuing with other packages (if any).");
			}
		}
	}

	void addLocalPackage(string path, string ver, bool system)
	{
		if (m_dryRun) return;
		m_packageManager.addLocalPackage(makeAbsolute(path), ver, system ? LocalPackageType.system : LocalPackageType.user);
	}

	void removeLocalPackage(string path, bool system)
	{
		if (m_dryRun) return;
		m_packageManager.removeLocalPackage(makeAbsolute(path), system ? LocalPackageType.system : LocalPackageType.user);
	}

	void addSearchPath(string path, bool system)
	{
		if (m_dryRun) return;
		m_packageManager.addSearchPath(makeAbsolute(path), system ? LocalPackageType.system : LocalPackageType.user);
	}

	void removeSearchPath(string path, bool system)
	{
		if (m_dryRun) return;
		m_packageManager.removeSearchPath(makeAbsolute(path), system ? LocalPackageType.system : LocalPackageType.user);
	}

	auto searchPackages(string query)
	{
		return m_packageSuppliers.map!(ps => tuple(ps.description, ps.searchPackages(query))).array
			.filter!(t => t[1].length);
	}

	/** Returns a list of all available versions (including branches) for a
		particular package.

		The list returned is based on the registered package suppliers. Local
		packages are not queried in the search for versions.

		See_also: `getLatestVersion`
	*/
	Version[] listPackageVersions(string name)
	{
		Version[] versions;
		foreach (ps; this.m_packageSuppliers) {
			try versions ~= ps.getVersions(name);
			catch (Exception e) {
				logDebug("Failed to get versions for package %s on provider %s: %s", name, ps.description, e.msg);
			}
		}
		return versions.sort().uniq.array;
	}

	/** Returns the latest available version for a particular package.

		This function returns the latest numbered version of a package. If no
		numbered versions are available, it will return an available branch,
		preferring "~master".

		Params:
			package_name: The name of the package in question.
			prefer_stable: If set to `true` (the default), returns the latest
				stable version, even if there are newer pre-release versions.

		See_also: `listPackageVersions`
	*/
	Version getLatestVersion(string package_name, bool prefer_stable = true)
	{
		auto vers = listPackageVersions(package_name);
		enforce(!vers.empty, "Failed to find any valid versions for a package name of '"~package_name~"'.");
		auto final_versions = vers.filter!(v => !v.isBranch && !v.isPreRelease).array;
		if (prefer_stable && final_versions.length) return final_versions[$-1];
		else if (vers[$-1].isBranch) return vers[$-1];
		else return vers[$-1];
	}

	void createEmptyPackage(Path path, string[] deps, string type,
		PackageFormat format = PackageFormat.sdl,
		scope void delegate(ref PackageRecipe, ref PackageFormat) recipe_callback = null)
	{
		if (!path.absolute) path = m_rootPath ~ path;
		path.normalize();

		string[string] depVers;
		string[] notFound; // keep track of any failed packages in here
		foreach (dep; deps) {
			Version ver;
			try {
				ver = getLatestVersion(dep);
				depVers[dep] = ver.isBranch ? ver.toString() : "~>" ~ ver.toString();
			} catch (Exception e) {
				notFound ~= dep;
			}
		}

		if(notFound.length > 1){
			throw new Exception(.format("Couldn't find packages: %-(%s, %).", notFound));
		}
		else if(notFound.length == 1){
			throw new Exception(.format("Couldn't find package: %-(%s, %).", notFound));
		}

		if (m_dryRun) return;

		initPackage(path, depVers, type, format, recipe_callback);

		//Act smug to the user.
		logInfo("Successfully created an empty project in '%s'.", path.toNativeString());
	}

	/** Converts the package recipe to the given format.

		Params:
			destination_file_ext = The file extension matching the desired
				format. Possible values are "json" or "sdl".
	*/
	void convertRecipe(string destination_file_ext)
	{
		import std.path : extension;
		import dub.recipe.io : writePackageRecipe;

		auto srcfile = m_project.rootPackage.packageInfoFilename;
		auto srcext = srcfile[$-1].toString().extension;
		if (srcext == "."~destination_file_ext) {
			logInfo("Package format is already %s.", destination_file_ext);
			return;
		}

		writePackageRecipe(srcfile[0 .. $-1] ~ ("dub."~destination_file_ext), m_project.rootPackage.info);
		removeFile(srcfile);
	}

	void runDdox(bool run)
	{
		if (m_dryRun) return;

		// allow to choose a custom ddox tool
		auto tool = m_project.rootPackage.info.ddoxTool;
		if (tool.empty) tool = "ddox";

		auto tool_pack = m_packageManager.getBestPackage(tool, ">=0.0.0");
		if (!tool_pack) tool_pack = m_packageManager.getBestPackage(tool, "~master");
		if (!tool_pack) {
			logInfo("% is not present, getting and storing it user wide", tool);
			tool_pack = fetch(tool, Dependency(">=0.0.0"), defaultPlacementLocation, FetchOptions.none);
		}

		auto ddox_dub = new Dub(m_packageSuppliers);
		ddox_dub.loadPackage(tool_pack.path);
		ddox_dub.upgrade(UpgradeOptions.select);

		auto compiler_binary = this.defaultCompiler;

		GeneratorSettings settings;
		settings.config = "application";
		settings.compiler = getCompiler(compiler_binary); // TODO: not using --compiler ???
		settings.platform = settings.compiler.determinePlatform(settings.buildSettings, compiler_binary);
		settings.buildType = "debug";
		settings.run = true;

		auto filterargs = m_project.rootPackage.info.ddoxFilterArgs.dup;
		if (filterargs.empty) filterargs = ["--min-protection=Protected", "--only-documented"];

		settings.runArgs = "filter" ~ filterargs ~ "docs.json";
		ddox_dub.generateProject("build", settings);

		auto p = tool_pack.path;
		p.endsWithSlash = true;
		auto tool_path = p.toNativeString();

		if (run) {
			settings.runArgs = ["serve-html", "--navigation-type=ModuleTree", "docs.json", "--web-file-dir="~tool_path~"public"];
			browse("http://127.0.0.1:8080/");
		} else {
			settings.runArgs = ["generate-html", "--navigation-type=ModuleTree", "docs.json", "docs"];
		}
		ddox_dub.generateProject("build", settings);

		if (!run) {
			// TODO: ddox should copy those files itself
			version(Windows) runCommand("xcopy /S /D "~tool_path~"public\\* docs\\");
			else runCommand("rsync -ru '"~tool_path~"public/' docs/");
		}
	}

	private void updatePackageSearchPath()
	{
		if (m_overrideSearchPath.length) {
			m_packageManager.disableDefaultSearchPaths = true;
			m_packageManager.searchPath = [m_overrideSearchPath];
		} else {
			auto p = environment.get("DUBPATH");
			Path[] paths;

			version(Windows) enum pathsep = ";";
			else enum pathsep = ":";
			if (p.length) paths ~= p.split(pathsep).map!(p => Path(p))().array();
			m_packageManager.disableDefaultSearchPaths = false;
			m_packageManager.searchPath = paths;
		}
	}

	private Path makeAbsolute(Path p) const { return p.absolute ? p : m_rootPath ~ p; }
	private Path makeAbsolute(string p) const { return makeAbsolute(Path(p)); }
}

string determineModuleName(BuildSettings settings, Path file, Path base_path)
{
	assert(base_path.absolute);
	if (!file.absolute) file = base_path ~ file;

	size_t path_skip = 0;
	foreach (ipath; settings.importPaths.map!(p => Path(p))) {
		if (!ipath.absolute) ipath = base_path ~ ipath;
		assert(!ipath.empty);
		if (file.startsWith(ipath) && ipath.length > path_skip)
			path_skip = ipath.length;
	}

	enforce(path_skip > 0,
		format("Source file '%s' not found in any import path.", file.toNativeString()));

	auto mpath = file[path_skip .. file.length];
	auto ret = appender!string;

	//search for module keyword in file
	string moduleName = getModuleNameFromFile(file.to!string);

	if(moduleName.length) return moduleName;

	//create module name from path
	foreach (i; 0 .. mpath.length) {
		import std.path;
		auto p = mpath[i].toString();
		if (p == "package.d") break;
		if (i > 0) ret ~= ".";
		if (i+1 < mpath.length) ret ~= p;
		else ret ~= p.baseName(".d");
	}

	return ret.data;
}

/**
 * Search for module keyword in D Code
 */
string getModuleNameFromContent(string content) {
	import std.regex;
	import std.string;

	content = content.strip;
	if (!content.length) return null;

	static bool regex_initialized = false;
	static Regex!char comments_pattern, module_pattern;

	if (!regex_initialized) {
		comments_pattern = regex(`(/\*([^*]|[\r\n]|(\*+([^*/]|[\r\n])))*\*+/)|(//.*)`, "g");
		module_pattern = regex(`module\s+([\w\.]+)\s*;`, "g");
		regex_initialized = true;
	}

	content = replaceAll(content, comments_pattern, "");
	auto result = matchFirst(content, module_pattern);

	string moduleName;
	if(!result.empty) moduleName = result.front;

	if (moduleName.length >= 7) moduleName = moduleName[7..$-1];

	return moduleName;
}

unittest {
	//test empty string
	string name = getModuleNameFromContent("");
	assert(name == "", "can't get module name from empty string");

	//test simple name
	name = getModuleNameFromContent("module myPackage.myModule;");
	assert(name == "myPackage.myModule", "can't parse module name");

	//test if it can ignore module inside comments
	name = getModuleNameFromContent("/**
	module fakePackage.fakeModule;
	*/
	module myPackage.myModule;");

	assert(name == "myPackage.myModule", "can't parse module name");

	name = getModuleNameFromContent("//module fakePackage.fakeModule;
	module myPackage.myModule;");

	assert(name == "myPackage.myModule", "can't parse module name");
}

/**
 * Search for module keyword in file
 */
string getModuleNameFromFile(string filePath) {
	string fileContent = filePath.readText;

	logDiagnostic("Get module name from path: " ~ filePath);
	return getModuleNameFromContent(fileContent);
}

enum UpgradeOptions
{
	none = 0,
	upgrade = 1<<1, /// Upgrade existing packages
	preRelease = 1<<2, /// inclde pre-release versions in upgrade
	forceRemove = 1<<3, /// Force removing package folders, which contain unknown files
	select = 1<<4, /// Update the dub.selections.json file with the upgraded versions
	printUpgradesOnly = 1<<5, /// Instead of downloading new packages, just print a message to notify the user of their existence
	useCachedResult = 1<<6, /// Use cached information stored with the package to determine upgrades
}

enum SkipRegistry {
	none,
	standard,
	all
}

class DependencyVersionResolver : DependencyResolver!(Dependency, Dependency) {
	protected {
		Dub m_dub;
		UpgradeOptions m_options;
		Dependency[][string] m_packageVersions;
		Package[string] m_remotePackages;
		SelectedVersions m_selectedVersions;
		Package m_rootPackage;
	}


	this(Dub dub, UpgradeOptions options)
	{
		m_dub = dub;
		m_options = options;
	}

	Dependency[string] resolve(Package root, SelectedVersions selected_versions)
	{
		m_rootPackage = root;
		m_selectedVersions = selected_versions;
		return super.resolve(TreeNode(root.name, Dependency(root.ver)), (m_options & UpgradeOptions.printUpgradesOnly) == 0);
	}

	protected override Dependency[] getAllConfigs(string pack)
	{
		if (auto pvers = pack in m_packageVersions)
			return *pvers;

		if (!(m_options & UpgradeOptions.upgrade) && m_selectedVersions.hasSelectedVersion(pack)) {
			auto ret = [m_selectedVersions.getSelectedVersion(pack)];
			logDiagnostic("Using fixed selection %s %s", pack, ret[0]);
			m_packageVersions[pack] = ret;
			return ret;
		}

		logDiagnostic("Search for versions of %s (%s package suppliers)", pack, m_dub.m_packageSuppliers.length);
		Version[] versions;
		foreach (p; m_dub.packageManager.getPackageIterator(pack))
			versions ~= p.ver;

		foreach (ps; m_dub.m_packageSuppliers) {
			try {
				auto vers = ps.getVersions(pack);
				vers.reverse();
				if (!vers.length) {
					logDiagnostic("No versions for %s for %s", pack, ps.description);
					continue;
				}

				versions ~= vers;
				break;
			} catch (Exception e) {
				logDebug("Package %s not found in %s: %s", pack, ps.description, e.msg);
				logDebug("Full error: %s", e.toString().sanitize);
			}
		}

		// sort by version, descending, and remove duplicates
		versions = versions.sort!"a>b".uniq.array;

		// move pre-release versions to the back of the list if no preRelease flag is given
		if (!(m_options & UpgradeOptions.preRelease))
			versions = versions.filter!(v => !v.isPreRelease).array ~ versions.filter!(v => v.isPreRelease).array;

		// filter out invalid/unreachable dependency specs
		versions = versions.filter!((v) {
				bool valid = getPackage(pack, Dependency(v)) !is null;
				if (!valid) logDiagnostic("Excluding invalid dependency specification %s %s from dependency resolution process.", pack, v);
				return valid;
			}).array;

		if (!versions.length) logDiagnostic("Nothing found for %s", pack);
		else logDiagnostic("Return for %s: %s", pack, versions);

		auto ret = versions.map!(v => Dependency(v)).array;
		m_packageVersions[pack] = ret;
		return ret;
	}

	protected override Dependency[] getSpecificConfigs(string pack, TreeNodes nodes)
	{
		if (!nodes.configs.path.empty && getPackage(pack, nodes.configs)) return [nodes.configs];
		else return null;
	}


	protected override TreeNodes[] getChildren(TreeNode node)
	{
		auto ret = appender!(TreeNodes[]);
		auto pack = getPackage(node.pack, node.config);
		if (!pack) {
			// this can hapen when the package description contains syntax errors
			logDebug("Invalid package in dependency tree: %s %s", node.pack, node.config);
			return null;
		}
		auto basepack = pack.basePackage;

		foreach (dname, dspec; pack.dependencies) {
			auto dbasename = getBasePackageName(dname);

			// detect dependencies to the root package (or sub packages thereof)
			if (dbasename == basepack.name) {
				auto absdeppath = dspec.mapToPath(pack.path).path;
				absdeppath.endsWithSlash = true;
				auto subpack = m_dub.m_packageManager.getSubPackage(basepack, getSubPackageName(dname), true);
				if (subpack) {
					auto desireddeppath = dname == dbasename ? basepack.path : subpack.path;
					desireddeppath.endsWithSlash = true;
					enforce(dspec.path.empty || absdeppath == desireddeppath,
						format("Dependency from %s to root package references wrong path: %s vs. %s",
							node.pack, absdeppath.toNativeString(), desireddeppath.toNativeString()));
				}
				ret ~= TreeNodes(dname, node.config);
				continue;
			}

			DependencyType dt;
			if (dspec.optional) {
				if (dspec.default_) dt = DependencyType.optionalDefault;
				else dt = DependencyType.optional;
			} else dt = DependencyType.required;

			if (m_options & UpgradeOptions.upgrade || !m_selectedVersions || !m_selectedVersions.hasSelectedVersion(dbasename)) {
				// keep deselected dependencies deselected by default
				if (m_selectedVersions && !m_selectedVersions.bare && dt == DependencyType.optionalDefault)
					dt = DependencyType.optional;
				ret ~= TreeNodes(dname, dspec.mapToPath(pack.path), dt);
			} else {
				// keep already selected optional dependencies if possible
				if (dt == DependencyType.optional) dt = DependencyType.optionalDefault;
				ret ~= TreeNodes(dname, m_selectedVersions.getSelectedVersion(dbasename), dt);
			}
		}
		return ret.data;
	}

	protected override bool matches(Dependency configs, Dependency config)
	{
		if (!configs.path.empty) return configs.path == config.path;
		return configs.merge(config).valid;
	}

	private Package getPackage(string name, Dependency dep)
	{
		auto basename = getBasePackageName(name);

		// for sub packages, first try to get them from the base package
		if (basename != name) {
			auto subname = getSubPackageName(name);
			auto basepack = getPackage(basename, dep);
			if (!basepack) return null;
			if (auto sp = m_dub.m_packageManager.getSubPackage(basepack, subname, true)) {
				return sp;
			} else if (!basepack.subPackages.canFind!(p => p.path.length)) {
				// note: external sub packages are handled further below
				auto spr = basepack.getInternalSubPackage(subname);
				if (!spr.isNull) {
					auto sp = new Package(spr, basepack.path, basepack);
					m_remotePackages[sp.name] = sp;
					return sp;
				} else {
					logDiagnostic("Sub package %s doesn't exist in %s %s.", name, basename, dep.version_);
					return null;
				}
			} else if (auto ret = m_dub.m_packageManager.getBestPackage(name, dep)) {
				return ret;
			} else {
				logDiagnostic("External sub package %s %s not found.", name, dep.version_);
				return null;
			}
		}

		if (!dep.path.empty) {
			try {
				auto ret = m_dub.packageManager.getOrLoadPackage(dep.path);
				if (dep.matches(ret.ver)) return ret;
			} catch (Exception e) {
				logDiagnostic("Failed to load path based dependency %s: %s", name, e.msg);
				logDebug("Full error: %s", e.toString().sanitize);
				return null;
			}
		}

		if (auto ret = m_dub.m_packageManager.getBestPackage(name, dep))
			return ret;

		auto key = name ~ ":" ~ dep.version_.toString();
		if (auto ret = key in m_remotePackages)
			return *ret;

		auto prerelease = (m_options & UpgradeOptions.preRelease) != 0;

		auto rootpack = name.split(":")[0];

		foreach (ps; m_dub.m_packageSuppliers) {
			if (rootpack == name) {
				try {
					auto desc = ps.getPackageDescription(name, dep, prerelease);
					auto ret = new Package(desc);
					m_remotePackages[key] = ret;
					return ret;
				} catch (Exception e) {
					logDiagnostic("Metadata for %s %s could not be downloaded from %s: %s", name, dep, ps.description, e.msg);
					logDebug("Full error: %s", e.toString().sanitize);
				}
			} else {
				logDiagnostic("Package %s not found in base package description (%s). Downloading whole package.", name, dep.version_.toString());
				try {
					FetchOptions fetchOpts;
					fetchOpts |= prerelease ? FetchOptions.usePrerelease : FetchOptions.none;
					fetchOpts |= (m_options & UpgradeOptions.forceRemove) != 0 ? FetchOptions.forceRemove : FetchOptions.none;
					m_dub.fetch(rootpack, dep, defaultPlacementLocation, fetchOpts, "need sub package description");
					auto ret = m_dub.m_packageManager.getBestPackage(name, dep);
					if (!ret) {
						logWarn("Package %s %s doesn't have a sub package %s", rootpack, dep.version_, name);
						return null;
					}
					m_remotePackages[key] = ret;
					return ret;
				} catch (Exception e) {
					logDiagnostic("Package %s could not be downloaded from %s: %s", rootpack, ps.description, e.msg);
					logDebug("Full error: %s", e.toString().sanitize);
				}
			}
		}

		m_remotePackages[key] = null;

		logWarn("Package %s %s could not be loaded either locally, or from the configured package registries.", name, dep);
		return null;
	}
}
