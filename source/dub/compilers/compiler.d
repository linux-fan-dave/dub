/**
	Compiler settings and abstraction.

	Copyright: © 2013-2016 rejectedsoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dub.compilers.compiler;

public import dub.compilers.buildsettings;
public import dub.platform : BuildPlatform, matchesSpecification;

import dub.compilers.dmd;
import dub.compilers.gdc;
import dub.compilers.ldc;
import dub.internal.vibecompat.core.file;
import dub.internal.vibecompat.core.log;
import dub.internal.vibecompat.data.json;
import dub.internal.vibecompat.inet.path;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.process;


static this()
{
	registerCompiler(new DMDCompiler);
	registerCompiler(new GDCCompiler);
	registerCompiler(new LDCCompiler);
}

/** Returns a compiler handler for a given binary name.

	The name will be compared against the canonical name of each registered
	compiler handler. If no match is found, the sub strings "dmd", "gdc" and
	"ldc", in this order, will be searched within the name. If this doesn't
	yield a match either, an exception will be thrown.
*/
Compiler getCompiler(string name)
{
	foreach (c; s_compilers)
		if (c.name == name)
			return c;

	// try to match names like gdmd or gdc-2.61
	if (name.canFind("dmd")) return getCompiler("dmd");
	if (name.canFind("gdc")) return getCompiler("gdc");
	if (name.canFind("ldc")) return getCompiler("ldc");

	throw new Exception("Unknown compiler: "~name);
}

/** Returns the binary name of the default compiler for the system.

	When calling this function for the first time, it will search the PATH
	environment variable for files named "dmd", "gdc", "gdmd", "ldc2", "ldmd2"
	(in that order) and return the first match. If no match is found, "dmd" is
	returned.
*/
@property string defaultCompiler()
{
	static string name;
	if (!name.length) name = findCompiler();
	return name;
}

private string findCompiler()
{
	import std.process : env=environment;
	version (Windows) enum sep = ";", exe = ".exe";
	version (Posix) enum sep = ":", exe = "";

	auto compilers = ["dmd", "gdc", "gdmd", "ldc2", "ldmd2"];

	auto paths = env.get("PATH", "").splitter(sep).map!Path;
	auto res = compilers.find!(bin => paths.canFind!(p => existsFile(p ~ (bin~exe))));
	return res.empty ? compilers[0] : res.front;
}

/** Registers a new compiler handler.

	Note that by default `DMDCompiler`, `GDCCompiler` and `LDCCompiler` are
	already registered at startup.
*/
void registerCompiler(Compiler c)
{
	s_compilers ~= c;
}


interface Compiler {
	@property string name() const;

	BuildPlatform determinePlatform(ref BuildSettings settings, string compiler_binary, string arch_override = null);

	/// Replaces high level fields with low level fields and converts
	/// dmd flags to compiler-specific flags
	void prepareBuildSettings(ref BuildSettings settings, BuildSetting supported_fields = BuildSetting.all) const;

	/// Removes any dflags that match one of the BuildOptions values and populates the BuildSettings.options field.
	void extractBuildOptions(ref BuildSettings settings) const;

	/// Adds the appropriate flag to set a target path
	void setTarget(ref BuildSettings settings, in BuildPlatform platform, string targetPath = null) const;

	/// Invokes the compiler using the given flags
	void invoke(in BuildSettings settings, in BuildPlatform platform, void delegate(int, string) output_callback);

	/// Invokes the underlying linker directly
	void invokeLinker(in BuildSettings settings, in BuildPlatform platform, string[] objects, void delegate(int, string) output_callback);

	/// Convert linker flags to compiler format
	string[] lflagsToDFlags(in string[] lflags) const;
	
	protected final void invokeTool(string[] args, void delegate(int, string) output_callback)
	{
		import std.string;

		int status;
		if (output_callback) {
			auto result = executeShell(escapeShellCommand(args));
			output_callback(result.status, result.output);
			status = result.status;
		} else {
			auto compiler_pid = spawnShell(escapeShellCommand(args));
			status = compiler_pid.wait();
		}

		version (Posix) if (status == -9) {
			throw new Exception(format("%s failed with exit code %s. This may indicate that the process has run out of memory.",
				args[0], status));
		}
		enforce(status == 0, format("%s failed with exit code %s.", args[0], status));
	}
}

private {
	Compiler[] s_compilers;
}
