//          Copyright Ferdinand Majerech 2015.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

import std.algorithm;
import std.array;
import std.conv: to;
import std.exception: assumeWontThrow, enforce;
import std.file: exists;
import std.path: absolutePath, buildPath, buildNormalizedPath, expandTilde, pathSplitter;
import std.range;
import std.stdio;
import std.string;
import std.typecons;

// Docs disk usage (hardlinks taken into account):
//
// 03.03.2015: 1803 MiB

//TODO future ideas:
// - Features:
//     * Cross-project cross-referencing.
//       Dependencies from dub.json will be considered for cross-referencing when
//       generating docs for a package. The links between projects should be absolute,
//       so e.g. after downloading docs for tharsis-core the links to tharsis-full still
//       work, as they point to ddocs.org.
//       When implemented, we can also have stuff like call graphs or class hierarchy
//       graphs referencing code from other projects.
//       Test cross-referencing on Tharsis projects.
//     * Phobos/Druntime cross-referencing
//       Will need special handling (Phobos is not a DUB project, needs a custom hmod.cfg
//       to pass dlang.org macros, probably needs to link to dlang.org docs, etc.)
//       Also, cross-referencing with Phobos/Druntime should be on by default, so docs for
//       any D projects can refer to them.
//     * JS search for packages using fuzzy matching (e.g. dml would match dyaml)
//       the search interface would be similar to search in generated docs.
//     * support tags in hmod.cfg/dub.json so ddocs.org can add package search by tag (with JS)
// - Maintenance:
//     * ddocs.org and hmod-dub should be DUB packages.
//     * replace the "package:version" indices used in pkgGenOutputs/statuses_ with
//       a struct - package name and version pair. Joining strings is unsafe and ugly.
// - Performance:
//     * run hmod-dub through /usr/bin/time and collect maxresident memory usage stats.
//       Log those in the detailed log and if greater than e.g. 256MiB, print a warning
//       to stdout.
//     * Use a separate max-doc-age for obsolete versions. Make it e.g. 25 days (default
//       max-doc-age is 5 days).
//     * Compress cached DUB packages for obsolete versions.  This should save a lot of
//       space as the DUB registry becomes bigger. hmod-dub needs to be able to recognize
//       these archives and unpack them instead of re-fetching the packages.
//     * Currently we attempt to generate docs every time for errored versions. If the
//       error was a failure to fetch this means we always try to re-fetch the version,
//       which takes some time and will take more as the DUB registry becomes bigger.
//       We need to remember errors and to avoid asking hmod-dub to generate these
//       packages based on how many previous attempts to generate resulted in an error.
//       Can do this in another YAML parallel to packages.yaml/versions.yaml.
//     * Using hardlinks for deduplication might solve the current 'disk usage by branches'
//       problem.
//     * We need a way to identify obsolete branches (last commit time? maybe we'll have
//       to clone them?) so we don't eat up space with docs for 100s of old branches per
//       project.

version(Posix) {}
// We use unix commands, etc.
else static assert(false, "ddocs.org only supports Posix systems (e.g. Linux)");

/** Configuration variables loaded from the command-line.
 */
struct Config
{
    // No default initialization allowed.
    @disable this();

    /** Path to the YAML file we store package rows for known packages in.
     *
     * Compared to current code.dlang.org content to identity updated packages.
     */
    string packagesListPath = "./packagelist.yaml";
    /** Path to the YAML file we store detailed data about known packages.
     *
     * Used to avoid always redownloading package data from code.dlang.org pages;
     * we only redownload if the package was updated.
     */
    string packageDataPath = "./packagedata.yaml";
    /// Directory to write the generated site/documentation into.
    string outputDirectory = "./public";
    /// Directory where DUB stores packages. Initialized by this().
    string dubDirectory = null;
    /// Path to the YAML file to write diagnostic data to.
    string diagnosticsPath = "./diagnostics.yaml";
    /** Maximum documentation age of non-branch package versions, in seconds.
     *
     * Documentation older than this will be regenerated.
     */
    ulong maxDocAge = 3600 * 24 * 5;
    // By default, regenerate docs for branches every day.
    /// Maximum documentation age of branch package versions (e.g. `~master`), in seconds.
    ulong maxDocAgeBranch = 3600 * 36;
    /** Maximum number of subprocesses `hmod-dub` can use.
     *
     * Note that running many process in parallel can result in massive worst-case memory
     * usage.
     */
    ulong maxProcesses = 1;
    /** Time limit for subprocesses used by `hmod-dub`.
     *
     * 120 seconds should be enough to generate docs for anything.
     */
    ulong processTimeLimit = 120;
    /** If true, skip documentation generation, generating only the index pages.
     *
     * DDocs.org will assume every package already has its documentation generated from
     * previous calls when creating links in index pages. Useful when testing quick
     * changes to the index pages.
     *
     * Generated pages should *NOT* be used in production. Some packages never have any
     * documentation generated because of e.g. errors in dub.json or no source files.
     */
    bool skipDocs = false;
    /** Skip generating documentation archives.
     *
     * DDocs.org will assume the archives already exist - links to them will be generated.
     */
    bool skipArchives = false;
    /// Print the help message.
    bool doHelp = false;
    /// Compression level to use for documentation archives. Must at least 0 and at most 9.
    uint compressionLevel = 3;
    /// Force regeneration of hardlinks even for versions whose documentation was not generated.
    bool forceHardlinks = false;
    /// Force regeneration of archives even for versions whose documentation was not generated.
    bool forceArchives = false;
    /// Reload all package/version info for from code.dlang.org (ignoring remembered info).
    bool forceInfoRefresh = false;
    /** Refetch all DUB packages
     *
     *  WARNING: Clears the DUB package cache. Renames the existing cache to backup name
     *  (dubDirectory ~ "-ddocs.bkp"), deleting any existing backup with that name.
     */
    bool forceDubRefetch = false;
    /// Path to the aggregate log file to store logs of all subprocesses in.
    string logYAMLPath = "./ddocs.org-log.yaml";
    /** Abort generating documentation if less than this amount of disk space is available.
     *
     * Note: free disk space is only checked between `hmod-dub` runs, so if a single
     * `hmod-dub` run generates more than this many GiB, we're out of space.
     */
    double diskReserveGiB = 4.0;
    /// Hmod will ignore any modules bigger than this many kiB.
    uint maxFileSizeK = 768;

    /** Minimum number of packages to show per index page.
     *
     * DDocs.org ensures all packages starting with the same character are on the same
     * page, so the actual number of packages on a page may be higher, but if there are
     * more than this many packages, the next starting character will be on another page.
     */
    uint minPackagesPerPage = 125;

    this(string[] args, ref Context context)
    {
        dubDirectory = "~/.dub/packages".expandTilde;
        import std.getopt;

        // Rebuild everything from scratch if specified.
        // Implies forceHardlinks, forceArchives, forceInfoRefresh, forceDubRefetch,
        // maxDocAge 0 and maxDocAgeBranch 0.
        bool forceFullRebuild;

        getopt(args, std.getopt.config.caseSensitive, std.getopt.config.passThrough,
               "h|help",               &doHelp,
               "p|process-count",      &maxProcesses,
               "d|dub-directory",      &dubDirectory,
               "t|process-time-limit", &processTimeLimit,
               "a|max-doc-age",        &maxDocAge,
               "b|max-doc-age-branch", &maxDocAgeBranch,
               "o|output-directory",   &outputDirectory,
               "P|package-list-path",  &packagesListPath,
               "A|package-data-path",  &packageDataPath,
               "c|compression-level",  &compressionLevel,
               "H|force-hardlinks",    &forceHardlinks,
               "A|force-archives",     &forceArchives,
               "I|force-info-refresh", &forceInfoRefresh,
               "R|force-dub-refetch",  &forceDubRefetch,
               "F|force-full-rebuild", &forceFullRebuild,
               "s|skip-docs",          &skipDocs,
               "S|skip-archives",      &skipArchives,
               "l|log-yaml-path",      &logYAMLPath,
               "D|disk-reserve-gib",   &diskReserveGiB,
               "m|packages-per-page",  &minPackagesPerPage,
               "M|max-module-size",    &maxFileSizeK,
               "d|diagnostics-path",   &diagnosticsPath
               );
        if(forceFullRebuild)
        {
            forceHardlinks = forceArchives = forceInfoRefresh = forceDubRefetch = true;
            maxDocAge = 0;
            maxDocAgeBranch = 0;
        }
        if(compressionLevel > 9)
        {
            context.writeln("ERROR: Compression level can be at most 9");
            doHelp = true;
        }
    }
}

/// Command-line help string.
auto helpString = q"(
-------------------------------------------------------------------------------
ddocs.org
Generates documentation for all DUB packages (code.dlang.org) using hmod.
Copyright (C) 2015 Ferdinand Majerech

Usage: ddocs.org [OPTIONS]

Examples:
    ddocs.org
        Generate documentation for all DUB packages in the './public'
        directory. If './public' already contains previously generated
        documentation, update it.
    ddocs.org -F
        Generate documentation in './public' from scratch, even if it
        already exists. WARNING: Clears the DUB package cache.
    ddocs.org -s
        Generate only the index pages pointing to documentation of individual
        packages ('./public/index.html', './public/index-page1.html', etc.).
        Useful when testing main page generation changes. Assumes the
        documentation has already been generated succesfully for all packages.
        WARNING: Generated pages should *NOT* be used in production.

Options:
    -h, --help                      Show this help message.
    -p, --process-count      COUNT  Maximum number of subprocesses `hmod-dub`
                                    (used by ddocs.org) can launch. The actual
                                    maximum number of processes is 2 + COUNT
                                    (`ddocs.org`, `hmod-dub` and hmod-dub
                                    subprocesses).
                                    Default: 1
    -d, --dub-directory      PATH   Directory where DUB stores fetched
                                    packages.
                                    Default: ~/.dub/packages
    -t, --process-time-limit SECS   Maximum time in seconds any `hmod-dub`
                                    subprocess (`hmod` or `dub fetch`) can
                                    spend. We give up on generating
                                    documentation for a package if we run out
                                    of this time.
                                    Default: 120
    -a, --max-doc-age        SECS   Maximum age of previously generated
                                    documentation in seconds. If documentation
                                    for a package already exists but is older
                                    than this, it will be overwritten.
                                    Default: 432000 (5 days)
    -b, --max-doc-age-branch SECS   Like --max-doc-age, but for branch versions
                                    of a package (e.g. ~master).
                                    Default: 129600 (1.5 days)
    -o, --output-directory   PATH   The directory to write generated
                                    documentation to.
                                    Default: ./public
    -P, --package-list-path  PATH   Path to a YAML file where a list of known
                                    packages is stored. Will be updated with any
                                    new packages.
                                    Will be created if it doesn't exist.
                                    Default: ./packagelist.yaml
    -A, --package-data-path  PATH   Path to a YAML file where detailed package
                                    data (including versions) is stored.
                                    Helps minimize dub registry page downloads.
                                    Will be updated with any changes detected.
                                    Will be created if it doesn't exist.
                                    Default: ./packagedata.yaml
    -c, --compression-level  LEVEL  Compression level to use (with xz, 7z) when
                                    generating compressed documentation
                                    archives. Must be at least 0 and at most 9.
                                    Default: 3
    -l, --log-yaml-path      PATH   Path to write a complete high-detail log
                                    to, including logs of all subprocesses and
                                    even `hmod-dub` subprocesses.
                                    Default: ./ddocs.org-log.yaml
    -D, --disk-reserve-gib   SIZE   Minumum disk space that should be left free
                                    in GiB. ddocs.org checks remaining disk
                                    space as it runs and aborts if less than
                                    SIZE is available. Note that these checks
                                    are not completely reliable and ddocs.org
                                    may still run out of space if too little is
                                    available.
                                    Default: 4
    -m, --packages-per-page  COUNT  Minimum number of packages to show per index
                                    page. ddocs.org ensures all packages with
                                    starting with the same character are on the
                                    same page, so the actual number of packages
                                    on a page may be higher, but if there are
                                    more than COUNT packages, the next starting
                                    character will be on another page.
                                    Default: 125
    -M, --max-module-size KILOBYTES Maximum module file size for `hmod` to
                                    process. Any modules bigger than this will
                                    be ignored. Helps avoid huge RAM usage.
                                    Default: 768 (0.75MiB)
    -H, --force-hardlinks           Force regeneration of hardlinks
                                    (e.g. `latest`) even for packages whose
                                    documentation wasn't updated.
    -A, --force-archives            Force regeneration of documentation
                                    archives even for packages/versions whose
                                    documentation was not updated.
    -I, --force-info-refresh        Force full reload of package and version
                                    information from the DUB registry, ignoring
                                    already known packages/versions.
    -R, --force-dub-refetch         Force full refetch of all DUB packages.
                                    WARNING: Clears the DUB package cache.
                                    Renames the existing cache to backup name
                                    (--dub-directory ~ "-ddocs.bkp"), deleting
                                    any existing backup with that name.
    -F, --force-full-rebuild        Force full rebuild of the documentation.
                                    Same as -a0 -b0 -H -A -I -R
    -s, --skip-docs                 Skip documentation generation, generate
                                    only the index pages (package lists).
                                    Assumes every package already has its
                                    documentation generated when creating
                                    links. Useful when testing quick changes
                                    to the index pages.
                                    WARNING: Generated pages should *NOT* be
                                    used in production. Some packages never
                                    have any documentation generated because of
                                    e.g. errors in dub.json or no source files.
    -S, --skip-archives             Don't generate documentation archives.
    -d, --diagnostics-path PATH     Path of a YAML file to write diagnostics
                                    data (execution time, disk space usage,
                                    etc.) to.
                                    Default: diagnostics.yaml
-------------------------------------------------------------------------------
)";

/** Documentation context.
 *
 * Pretty much one big dump of variables that are worked on during documentation
 * generation.
 */
struct Context
{
private:
    import yaml;

    /** Diagnostics stored in a `diagnostics.yaml` for every ddocs.run to determine how
     * overhead evolves over time.
     */
    struct Diagnostics
    {
        // Can't measure disk usage because `du` is too slow - at least on ext4.
        // Reconsider du when we run on different FS and/or an SSD.
        // ulong dubCacheSizeM;
        // ulong docsSizeM;
        // ulong txzSizeM;
        // ulong _7zSizeM;

        /// Total run time.
        ulong totalTimeS;
        /// Time spent generating documentation, *including* archiving.
        ulong docTimeS;
        /// Time spent archiving only. `double` used because we add up small fractions.
        double archiveTimeS = 0.0f;
        /// Time spent generating hardlinks.
        ulong hardlinkTimeS;
        /// Maximum RAM usage of `hmod`.
        ulong hmodRAMMaxK;

        /// Finish gathering diagnostics and dump them to `config.diagnosticsPath`.
        void finish(ref const Config config)
        {
            auto file = File(config.diagnosticsPath, "a");

            import std.datetime;
            file.writefln("- %s:", Clock.currTime.toISOExtString());
            file.writefln("  totalTimeS:    %s", totalTimeS);
            file.writefln("  docTimeS:      %s", docTimeS);
            file.writefln("  archiveTimeS:  %s", cast(ulong)archiveTimeS);
            file.writefln("  hardlinkTimeS: %s", hardlinkTimeS);
            file.writefln("  hmodRAMMaxK:   %s", hmodRAMMaxK);
        }
    }

    /// Diagnostics data to write to a file to compare between `ddocs.org` runs.
    Diagnostics diagnostics;

    /// Commands executed so far through runCmd/runShell (each command includes all arguments).
    string[] commands;
    /// Outputs (stdout/stderr) of commands, in same order.
    string[] cmdOutputs;

    /// Outputs of `hmod-dub` subcommands, indexed by "package:version" names.
    string[string] pkgGenOutputs;

    /// Output of ddocs.org itself (same as stdout).
    string directOutput;

    /** Package data, indexed by package name.
     *
     * Set exactly once through the `packageData` setter.
     */
    Package[string] packageData_;


    /** Documentation generation statuses, indexed by "package:version" names.
     *
     * Set exactly once through the `statuses` setter.
     */
    DocsStatus[string] statuses_;

public:
    /// Set package data once it is loaded. Must be called exactly once.
    void packageData(Package[string] rhs) @safe pure nothrow @nogc
    {
        assert(packageData_ is null, "Context.packageData can be set only once");
        packageData_ = rhs;
    }

    /// Set documentation generation statuses once generated. Must be called exactly once.
    void statuses(DocsStatus[string] rhs) @safe pure nothrow @nogc
    {
        assert(statuses_ is null, "Context.statuses can be set only once");
        statuses_ = rhs;
    }

    /// Package data, indexed by package name.
    const(Package[string]) packageData() @safe pure nothrow const @nogc { return packageData_; }

    /// Documentation generation statuses, indexed by "package:version" names.
    const(DocsStatus[string]) statuses() @safe pure nothrow const @nogc { return statuses_; }

    /// Get documentation status of specified version of specified package.
    const(DocsStatus) status(string pkgName, const Version ver) @safe pure nothrow const
    {
        import std.exception: assumeWontThrow;
        return statuses_["%s:%s".format(pkgName, ver.name).assumeWontThrow];
    }

    /// Get a YAML node with logs of ddocs.org and subprocesses, including hmod-dub subprocesses.
    Node logYAML()
    {
        return Node(["main-log" : Node(directOutput),
                     "command-logs": Node(commands, cmdOutputs),
                     "hmod-dub-subcommand-logs": Node(pkgGenOutputs)]);
    }

    import std.traits: ReturnType;
    /** Run specified command and record its output.
     *
     * Params: args = Command arguments. args[0] is the command name.
     *
     * Returns: Exit status and output of the command, as returned by `std.process.execute`.
     */
    auto runCmd(string[] args ...)
    {
        import std.process;
        const command = args.map!(a => "'%s'".format(a)).join(" ");
        this.writefln("== Running `%s` ==", command);
        auto result = execute(args);
        commands ~= command;
        cmdOutputs ~= result.output;
        return result;
    }

    /** Run specified command in the shell and record its output.
     *
     * Params: shellCmd = Full command string, as it would be entered into the shell.
     *         quiet    = If true, don't record the output. Useful for commands with
     *                    huge amount of useless output like `7z`.
     *
     * Returns: Exit status and output of the command, as returned by `std.process.execute`.
     */
    auto runShell(string shellCmd, Flag!"quiet" quiet = No.quiet)
    {
        import std.process;
        this.writefln("== Running `%s` ==", shellCmd);
        auto result = executeShell(shellCmd);
        if(!quiet)
        {
            commands ~= shellCmd;
            cmdOutputs ~= result.output;
        }
        return result;
    }

    /// Write a "heading" when doing something major - and record it.
    void writeHeading(string text)
    {
        this.writeln("\n", text);
        this.writeln("=".repeat(text.length).join);
    }

    /// A `std.stdio.writeln` wrapper that records its output.
    void writeln(S ...)(S args)
    {
        .writeln(args);
        foreach(arg; args) { directOutput ~= arg.to!string; }
        directOutput ~= "\n";
    }

    /// A `std.stdio.writefln` wrapper that records its output.
    void writefln(S ...)(S args)
    {
        .writefln(args);
        directOutput ~= args[0].format(args[1 .. $]);
    }
}

/** Program entry point.
 *
 * Contains the high-level structure of the program.
 */
int main(string[] args)
{
    Context context;
    auto totalTimer = Timer("Total run time", context);
    auto config = Config(args, context);
    if(config.doHelp)
    {
        writeln(helpString);
        return 0;
    }

    // At exit, dump diagnostics and the uber-verbose log.
    scope(exit)
    {
        import yaml;
        context.diagnostics.totalTimeS = cast(ulong)totalTimer.ageSeconds;
        context.diagnostics.finish(config);
        Dumper(config.logYAMLPath).dump(context.logYAML);
        writeln("Peak memory usage of ddocs.org itself (kiB): ", peakMemoryUsageK);
    }
    int error(S...)(S args) { context.writeln("ERROR: ", args); return 1; }

    // Remove the DUB package directory if we need to refetch everything.
    import std.exception: collectException;
    if(config.forceDubRefetch) if(auto e = collectException({ removeDubDir(config, context); }()))
    {
        return error("Failed to remove the dub directory (needed to force refetch)", e);
    }

    if(auto e = collectException({ context.packageData = getPackageData(config, context); }()))
    {
        return error("Failed to get package data: ", e);
    }
    scope(success) { savePackageData(config, context); }

    write("\n");
    const totalPackageVersionCount =
        context.packageData.byValue.map!(v => v.versions.length).sum;
    context.writefln("Got info about %s packages, with %s versions total",
                     context.packageData.length, totalPackageVersionCount);

    // Generate docs and create documentation archives for all packages.
    context.writeHeading("Generating documentation");
    DocsStatus[string] generateAllDocs()
    {
        auto timer = Timer("Generating documentation", context);
        DocsStatus[string] statuses;
        // Work with one package at a time.
        foreach(name; context.packageData.byKey)
        {
            generateDocs(name, statuses, config, context);
            archiveDocs(name, statuses, config, context);
        }
        context.diagnostics.docTimeS = cast(ulong)timer.ageSeconds;
        return statuses;
    }
    if(auto e = collectException({ context.statuses = generateAllDocs(); }()))
    {
        return error("Failed generating docs: ", e);
    }

    if(!config.skipDocs) { writeDocGenerationStatus(config, context); }

    // Write `ddocs.org` HTML itself (index, status pages).
    context.writeHeading("Generating ddocs.org HTML");
    if(auto e = collectException({writeHTML(config, context);}()))
    {
        return error("Failed to generate ddocs.org HTML pages: ", e);
    }

    // Create hardlinks for `latest` version of packages.
    if(auto e = collectException({latestLinks(config, context);}()))
    {
        return error("Failed to create hardlinks to latest package versions: ", e);
    }

    return 0;
}


/// Write aggreagated information about documentation generation status to stdout.
void writeDocGenerationStatus(const ref Config config, ref Context context)
{
    // Readability shortcut
    void line(S ...)(S args) { context.writefln(args); }

    context.writeHeading("Documentation generation status");
    auto svals = context.statuses.byValue;
    line("Successes: %s", svals.count!((ref s) => s.errors.empty));
    line("Failures: %s, of those %s fatal", svals.count!((ref s) => !s.errors.empty),
          svals.count!((ref s) => s.errors.canFind("FATAL")));

    //TODO byKeyValue.array in dmd 2.067
    auto sKeyVals = context.statuses.byKey.map!(k => tuple(k, cast(DocsStatus)context.statuses[k])).array;

    auto byHmodRAM = sKeyVals.sort!((a, b) => a[1].hmodRAM > b[1].hmodRAM);
    line("32 worst `hmod` memory usages (kiB): \n%s",
         byHmodRAM.take(32).map!(kv => "  %s: %s\n".format(kv[0], kv[1].hmodRAM)).joiner());
    context.diagnostics.hmodRAMMaxK = byHmodRAM.empty ? 0 : byHmodRAM.front[1].hmodRAM;
    line("\nUnknown errors: %s\n", svals.count!((ref s) => s.errors.canFind("Unknown error")));
    foreach(name, status; context.statuses) if(!status.errors.empty)
    {
        line("%s:", name);
        foreach(e; status.errors) { context.writeln("    ", e); }
    }
}


/** Remove the DUB package cache to force re-fetching of all packages.
 *
 * Moves the dub directory into `$dubDirectory-ddocs-bkp`. If that backup directory
 * exists, it is deleted first.
 */
void removeDubDir(const ref Config config, ref Context context)
{
    context.writeHeading("Removing the DUB package directory (to force refetch of all packages)");
    if(!config.dubDirectory.exists) { return; }
    // Moves the .dub directory into a backup directory. If a backup dir already exists,
    // deletes it furst.
    const bkpDir = config.dubDirectory.buildNormalizedPath ~ "-ddocs-bkp";
    import std.file: rmdirRecurse, rename;
    if(bkpDir.exists) { bkpDir.rmdirRecurse; }
    config.dubDirectory.rename(bkpDir);
}

/** Generate documentation archives for all versions of a package and delete generated docs
 * for obsolete versions.
 *
 * Params:
 *
 * pkgName  = Name of the packages.
 * statuses = Package generation statuses. Guaranteed to have doc statuses for this
 *              package but may not have statuses for all packages.
 * config   = Config for output directory and various options.
 * context  = Context for package/version information.
 *
 * Throws: `Exception` if an archiving/deletion command fails.
 */
void archiveDocs(string pkgName, DocsStatus[string] statuses,
                 const ref Config config, ref Context context)
{
    // If we didn't generate any docs we have nothing to archive either.
    if(config.skipDocs || config.skipArchives) { return; }
    auto timer = Timer("Creating documentation archives for '%s'".format(pkgName), context);
    scope(exit) { context.diagnostics.archiveTimeS += timer.ageSeconds; }
    foreach(pkgVer; context.packageData[pkgName].versions)
    {
        // If we did not generate any docs this time, don't archive anything (unless forced).
        if(!config.forceArchives &&
           !statuses["%s:%s".format(pkgName, pkgVer.name)].didGenerateDocs)
        {
            continue;
        }

        const freeGiB = freeSpaceGiB();
        enforce(freeGiB > config.diskReserveGiB,
                new Exception("Disk space fell below reserved %.3f GiB to %.3f GiB"
                              .format(config.diskReserveGiB, freeGiB)));
        const dir = config.pkgPath(pkgName, pkgVer.name);

        const xzCmd = "tar -c '%s' | xz -%sv > '%s.txz'".format(dir, config.compressionLevel, dir);
        const _7zCmd = "7z a -mx%s '%s.7z' '%s'".format(config.compressionLevel, dir, dir);
        foreach(cmd; only(xzCmd, _7zCmd))
        {
            const result = context.runShell(cmd, cmd is _7zCmd ? Yes.quiet : No.quiet);
            enforce(result.status == 0,
                    new Exception("%s failed with status %s: output:\n%s"
                                  .format(cmd, result.status, result.output)));
        }

        // Note that deleting generated docs here won't trigger a regenerate immediately
        // at the next hmod-dub run, because the .time file written by hmod-dub to check
        // age of generated documentation is outside the archived/deleted directory.
        final switch(pkgVer.type) with(VersionType)
        {
            // Keeping all Branches is questionable, but useful because it allows to look
            // at documentation before merging a branch. But at any given time in a mature
            // project, most branches will be obsolete.
            case Latest, LatestOldMinor, Prerelease, BranchMaster, Branch: break;
            // Must be in sync with archiveOnly in addVersion in generateIndexPage.
            // (the versions whose documentation is deleted are archive only)
            case PrereleaseObsolete, Obsolete:
                context.writefln("Removing directory '%s' after archiving (obsolete "
                                 "package version)", dir);
                import std.file: rmdirRecurse;
                dir.rmdirRecurse();
                break;
            case UNINITIALIZED:
                context.writeln("ERROR: UNINITIALIZED version type when archiving docs; ignoring");
        }
    }
}

/** Get the path of generated documentation for a package.
 *
 * Params:
 *
 * config  = Config for the output directory.
 * pkgName = Name of the package.
 * verName = Name of the package version.
 */
string pkgPath(const ref Config config, string pkgName, string verName)
{
    return config.outputDirectory.buildPath(pkgName, verName.tr("+", "_"));
}

/** Create hardlinks for the latest versions of packages (the `ddocs.org/$pkg/latest` paths).
 *
 * Params:
 *
 * config  = Configuration for the output directory.
 * context = Context for package/version info.
 */
void latestLinks(const ref Config config, ref Context context)
{
    if(config.skipDocs) { return; }
    context.writeHeading("Creating hardlinks");
    auto timer = Timer("Creating hardlinks", context);
    scope(exit) { context.diagnostics.hardlinkTimeS = cast(ulong)timer.ageSeconds; }

    // Nothing to hardlink if we didn't generate docs.
    foreach(pkgName, pkgData; context.packageData)
    {
        auto latest = pkgData.versions.latestVersion;
        if(!latest.isNull)
        {
            void hardlink(const string from, const string to)
            {
                // May not exist if failed to generate docs for the latest version and we're
                // skipping doc generation.
                if(!from.exists) { return; }
                if(to.exists) { context.runCmd("rm", "-r", "-f", to); }
                // Create hardlinks to ensure copy-ability
                const result = context.runCmd("cp", "-a", "-l", from, to);
                enforce(result.status == 0,
                        new Exception("cp -a -l failed with status %s: output:\n%s"
                                      .format(result.status, result.output)));
            }

            auto status = context.status(pkgName, latest);

            const to   = config.pkgPath(pkgName, "latest");
            const from = config.pkgPath(pkgName, latest.name);
            // If there were errors, still need the hardlink - for the status page.
            if(status.didGenerateDocs || !status.errors.empty || config.forceHardlinks)
            {
                hardlink(from, to);
            }
            // If there were errors, we have no arcchives.
            if(status.didGenerateDocs || (status.errors.empty && config.forceHardlinks))
            {
                hardlink(from ~ ".txz", to ~ ".txz");
                hardlink(from ~ ".7z", to ~ ".7z");
            }
        }
    }
}

/** Describes a package index page.
 *
 * The index pages list packages in alphabetic order, with each page handling a range of
 * characters, e.g. "a - d", "e - s", etc.
 */
struct IndexPage
{
    /// First starting character of packages to be included in the page.
    char startCharMin;
    /// Last starting character of packages to be included in the page (inclusive).
    char startCharMax;
    /// Index of the page (which page in order this is).
    size_t index;

    /// Get file name for the page.
    string fileName() const nothrow
    {
        // The first page is `index.html`, other pages are numbered.
        return index == 0 ? "index.html" : "index-page%s.html".format(index).assumeWontThrow;
    }

    /// Get the name of the page (identifying its alphabetic range).
    string name() const nothrow
    {
        return "%s - %s".format(startCharMin, startCharMax).assumeWontThrow;
    }

    /// Determine if specified character is in the page's alphabetic range.
    bool includes(char c) const nothrow
    {
        return c >= startCharMin && c <= startCharMax;
    }
}

/** Split packages into pages *longer* than config.minPackagesPerPage.
 *
 * The pages are as short as possible, but all packages with the same name are always on
 * the same page.
 */
IndexPage[] paginate(ref const Config config, ref Context context)
{
    auto pkgNames = context.packageData.byKey.array.sort;
    IndexPage[] result;
    auto startCharGroups = pkgNames.map!(k => cast(char)k.front).group.array;

    // Inefficient as fuck, but should work for now.
    typeof(startCharGroups.front)[] page;
    foreach(group; startCharGroups)
    {
        page ~= group;
        if(page.map!(g => g[1]).sum > config.minPackagesPerPage)
        {
            assert(!page.empty, "Can't add an empty page");
            result ~= IndexPage(page.front[0], page.back[0], result.length);
            destroy(page);
        }
    }
    if(!page.empty)
    {
        result ~= IndexPage(page.front[0], page.back[0], result.length);
    }

    return result;
}

/** Write ddocs.org HTML content.
 *
 * Params:
 *
 * config  = Config for paths, settings, etc.
 * context = Context for package/version info, documentation generation statuses, etc.
 */
void writeHTML(ref const Config config, ref Context context)
{
    auto timer = Timer("Generating DDocs.org HTML", context);
    import std.file;
    // Use hmod style as a base and our own style for modifications.
    const styleHmod = config.outputDirectory.buildPath("style-hmod.css");

    if(styleHmod.exists) { std.file.remove(styleHmod); }
    context.runCmd("hmod", "--generate-css", styleHmod);

    File(config.outputDirectory.buildPath("style-ddocs.org.css"), "w").write(ddocsOrgCSS);

    File(config.outputDirectory.buildPath("favicon.png"), "w").write(faviconData);

    auto pages = paginate(config, context);
    // Generate index pages.
    foreach(IndexPage page; pages)
    {
        auto index = File(config.outputDirectory.buildPath(page.fileName), "w");
        auto indexWriter = index.lockingTextWriter;
        generateIndexPage(indexWriter, page, pages, context);
    }

    // Generate status (error) pages for package versions where we failed to generate docs.
    foreach(pkgName, pkgData; context.packageData) foreach(ver; pkgData.versions)
    {
        const status = context.status(pkgName, ver);
        if(!status.errors.empty)
        {
            const docIndexPath = config.pkgPath(pkgName, ver.name).buildPath("index.html");
            auto docIndex = File(docIndexPath, "w");
            // version name may include a path separator
            const docIndexDepth = 1 + ver.name.pathSplitter.walkLength;
            auto docIndexWriter = docIndex.lockingTextWriter;
            generateStatusPage(docIndexWriter, docIndexDepth, status);
        }
    }
}

/** Generate a status page for a version where we failed to generate documentation.
 *
 * Params:
 *
 * dst    = Range to write generated HTML to.
 * depth  = Depth of the page in the filesystem (to ensure correct link paths).
 * status = Documentation generation status for error info.
 */
void generateStatusPage(R)(ref R dst, size_t depth, ref const DocsStatus status)
{
    dst.generateDDocsHeader("Error: Failed to generate documentation", depth);

    dst.generateBreadcrumbs({ dst.put(`Failed to generate documentation`); });

    dst.put(`<strong>Errors encountered:</strong>`);
    dst.put(`<ul class="errors">`);
    foreach(error; status.errors)
    {
        dst.putAll(`<li>`, error, `</li>`);
    }
    dst.put(`</ul>`);
    scope(exit) { dst.generateDDocsFooter(); }
}


/** Generate header of a page.
 *
 * Params:
 *
 * dst   = Range to write generated HTML to.
 * title = Page title.
 * depth = Depth of the page in the filesystem (to ensure correct CSS paths).
 */
void generateDDocsHeader(R)(ref R dst, string title, size_t depth)
{
    const dstring relative = "../".repeat(depth).joiner.array;
    dst.put(
`<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8"/>
<link rel="stylesheet" type="text/css" href="%sstyle-hmod.css"/>
<link rel="stylesheet" type="text/css" href="%sstyle-ddocs.org.css"/>
<link rel="icon" type="image/png" href="%sfavicon.png" />
<title>%s</title>
</head>
<body>
<div class="main">`.format(relative, relative, relative, title));
}

/** Generate breadcrumbs at the top of a page.
 *
 * Params:
 *
 * dst             = Range to write generated HTML to.
 * generateContent = Delegate to generate content inside the breadcrumbs.
 */
void generateBreadcrumbs(R)(ref R dst, void delegate() generateContent)
{
    dst.put(`<div class="breadcrumbs">`);
    generateContent();
    dst.put(`</div>`);
    dst.put(`<div class="ddocs-content">`);
}

/// Generate the site footer.
void generateDDocsFooter(R)(ref R dst)
{
    dst.put(
`</div>
</div>
<footer>
Generated with <a href="https://github.com/kiith-sa/ddocs.org">DDocs.org</a> by
<a href="http://defenestrate.eu">Ferdinand Majerech</a>.
</footer>
</body>
</html>`);
}


/** Generate a package index HTML page.
 *
 * Starts with the description of `ddocs.org` and project author info. Main content is
 * a table of links to package documentation.
 *
 * Params:
 *
 * dst      = Range to write generated HTML to.
 * thisPage = `IndexPage` struct describing this page, e.g. the alphabetic range of
 *            packages to be shown on the page.
 * pages    = All index page structs. Needed to generate links pointing to correct pages.
 * context  = Context for package info/versions.
 */
void generateIndexPage(R)(ref R dst,
                          const IndexPage thisPage,
                          ref const IndexPage[] pages,
                          ref const Context context)
{
    dst.generateDDocsHeader("DDocs.org", 0);
    import dmarkdown;
    scope(exit) { dst.generateDDocsFooter(); }

    auto pkgNames = context.packageData.byKey.array.sort;
    auto startChars = pkgNames.map!(k => cast(char)k.front).uniq;
    // Breadcrumbs contain the alphabetic shortcut links.
    dst.generateBreadcrumbs({
        dst.putAll(`<div class="alpha">`, "\n");
        foreach(c; startChars)
        {
            auto link = pages.find!(p => p.includes(c)).front.fileName();
            dst.putAll(`<a href="` ~ link ~ `#`, c, `">`, c, `</a>`);
        }
        dst.putAll("\n", `</div>`, "\n");
        dst.putAll(`<div class="title">DDocs.org: [`, thisPage.name, `]</div>`);
    });

    // Description/explanantion text at the top of the page
    dst.put(`<div class="header"><div class="main-description">`);
    dst.put(filterMarkdown(mainDescription, MarkdownFlags.backtickCodeBlocks));
    dst.put(`</div>`);
    dst.put(`<div class="project-developers">`);
    dst.put(filterMarkdown(projectDevelopers, MarkdownFlags.backtickCodeBlocks));
    dst.putAll(`</div></div>`, "\n");

    // "+ pages.length" avoids negative modulo issues.
    const prevPage = pages[(thisPage.index - 1 + pages.length) % pages.length];
    const nextPage = pages[(thisPage.index + 1 + pages.length) % pages.length];
    dst.putAll(`<a href="`, prevPage.fileName, `" class="prev"><span>`, prevPage.name, `</span></a>`, "\n");
    dst.putAll(`<a href="`, nextPage.fileName, `" class="next"><span>`, nextPage.name, `</span></a>`, "\n");

    // Only draw packages with startchars contained by thisPage
    char currentStartChar = cast(char)(thisPage.startCharMin - 1);
    dst.putAll(`<table class="package-list">`, "\n");
    foreach(pkgName; pkgNames.filter!(name => thisPage.includes(cast(char)name.front)))
    {
        const startChar = cast(char)pkgName.front;
        scope(exit) { currentStartChar = startChar; }
        // If this is the first package starting with a new char, add anchor for fast access
        auto anchor = startChar != currentStartChar
            ? `<a class="letter" id="` ~ startChar ~ `"></a>`
            : "";
        generateIndexPageRow(dst, anchor, pkgName, context);
    }
    dst.put("</table>\n");
}


/** Generate a 'row' in the index page, with name,documentation links,description of a package.
 *
 * Actually generates two `<tr>`'s, first for the name and links, second for the description.
 *
 * Params:
 *
 * dst     = Range to write generated HTML to.
 * anchor  = Anchor to insert into the `<tr>` (for links). Empty if no anchor. Used for
 *           the links pointing to the first package with name starting by each character.
 * pkgName = Name of the package.
 * context = Context for package info/versions.
 */
void generateIndexPageRow(R)(ref R dst, string anchor, string pkgName,
                             ref const Context context)
{
    const pkgBase = "http://code.dlang.org/packages/";

    // Package name and docs row
    dst.put(`<tr>`);

    // Package name and dub link.
    dst.putAll(`<td>`, anchor, `<span>`, pkgName, `</span><a href="`,
            pkgBase, pkgName, `">dub</a></td>`);
    auto pkgVersions = context.packageData[pkgName].versions;

    void addVersion(const Version ver)
    {
        auto errors = context.status(pkgName, ver).errors;

        // Must be in sync with the final switch in archiveDocs()
        // (the versions whose documentation is deleted are archive only)
        bool archiveOnly = only(VersionType.Obsolete, VersionType.PrereleaseObsolete)
            .canFind(ver.type);
        dst.put(archiveOnly ? ` <span `:` <a `);
        if(!errors.empty)          { dst.put(`class="error" `); }
        else final switch(ver.type) with(VersionType)
        {
            case Latest:             dst.put(`class="latest" `);         break;
            case Prerelease:         dst.put(`class="prerelease" `);     break;
            case PrereleaseObsolete: dst.put(`class="prerelease-old" `); break;
            case BranchMaster:       dst.put(`class="master" `);         break;
            case LatestOldMinor:     dst.put(`class="latest-old" `);     break;
            case Branch:             dst.put(`class="branch" `);         break;
            case Obsolete:           dst.put(`class="obsolete" `);       break;
            // Should never happen, but show an obvious error instead of assert(false) here.
            case UNINITIALIZED:      dst.put(`class="logic-error"`);     break;
        }
        const path = ver.type == VersionType.Latest ? "latest" : ver.name.tr("+", "_");
        if(archiveOnly)
        {
            dst.putAll(`>`, ver.name, `</span>`);
        }
        else
        {
            dst.putAll(`href="`, pkgName, `/`, path, `/index.html">`, ver.name, `</a>`);
        }

        if(errors.empty)
        {
            dst.putAll(`<a class="txz" href="`, pkgName, `/`, path, `.txz">txz</a>`);
            dst.putAll(`<a class="_7z" href="`, pkgName, `/`, path, `.7z">7z</a>`);
        }
    }

    dst.put(`<td>`);
    auto latest = pkgVersions.find!(v => v.type == VersionType.Latest);
    auto master = pkgVersions.find!(v => v.type == VersionType.BranchMaster);
    if(!latest.empty) { addVersion(latest.front); }
    if(!master.empty) { addVersion(master.front); }
    foreach(ver; pkgVersions) with(VersionType)
    {
        if(!only(Latest, BranchMaster).canFind(ver.type)) { addVersion(ver); }
    }
    dst.put(`</td>`);
    dst.put(`</tr>`);

    // Description row
    dst.putAll(`<tr><td colspan="2">`, context.packageData[pkgName].description, "</td></tr>\n");
}



/** Generate documentation for all versions of a package.
 *
 * Params:
 *
 * pkgName  = Name of the package.
 * statuses = Associative array to add doc generation statuses for individual versions
 *            (to keep track of errors for each version). Indexed by "packageName:version".
 * config   = Config for various parameters needed by `hmod-dub`.
 * context  = Context for package version information.
 *
 * Returns: false in case of a `hmod-dub` fatal error (no documentation generated).
 *          true otherwise.
 *
 * Throws:  Exception on un-recoverable error (e.g. `hmod-dub` not installed).
 */
bool generateDocs(string pkgName, ref DocsStatus[string] statuses,
                  ref const Config config, ref Context context)
{
    assert(config.dubDirectory !is null, "Uninitialized config.dubDirectory");
    enum statusFileName = "hmod-dub-package-status.yaml";

    auto versions = context.packageData[pkgName].versions;
    auto fullVersionNames = versions.map!(v => "%s:%s".format(pkgName, v.name));

    // Create empty doc statuses if we're skipping doc generation.
    if(config.skipDocs)
    {
        context.writeln("Skipping doc generation enabled; assuming all docs generated OK");
        foreach(name; fullVersionNames) { statuses[name] = DocsStatus([]); }
        return true;
    }

    // Check if we have enough free space.
    const freeGiB = freeSpaceGiB();
    if(freeGiB <= config.diskReserveGiB)
    {
        throw new Exception("Disk space fell below reserved %.3f GiB to %.3f GiB"
                            .format(config.diskReserveGiB, freeGiB));
    }

    auto args = ["hmod-dub",
                 "--output-directory",    config.outputDirectory,
                 "--process-count",       config.maxProcesses.to!string,
                 "--dub-directory",       config.dubDirectory,
                 "--process-time-limit",  config.processTimeLimit.to!string,
                 "--max-doc-age",         config.maxDocAge.to!string,
                 "--max-doc-age-branch",  config.maxDocAgeBranch.to!string,
                 "--status-output-path",  statusFileName,
                 "--max-file-size",       config.maxFileSizeK.to!string,
                 "--additional-toc-link", "DDocs.org:index.html"] ~
                 fullVersionNames.array;
    // Run `hmod-dub`.
    const result = context.runCmd(args);

    // Remove the hmod-dub documentation status (see --status-output-path) file at scope exit
    import std.file: remove;
    scope(exit) if(statusFileName.exists)
    {
        std.file.remove(statusFileName);
    }
    if(result.status == 1)
    {
        foreach(name; fullVersionNames) { statuses[name] = DocsStatus(["FATAL"], false); }
        context.writeln("FATALLY FAILED to generate documentation for ", pkgName);
        return false;
    }

    // Read the status file to get e.g. error, memory usage info.
    import yaml;
    auto statusNode = Loader(statusFileName).load();
    size_t errorsCount;
    foreach(name; fullVersionNames)
    {
        string[] errors;
        foreach(string error; statusNode[name]["errors"]) { errors ~= error; }
        const didGenerate = statusNode[name]["didGenerateDocs"].as!bool;
        context.pkgGenOutputs[name] = statusNode[name]["subprocessLog"].as!string;

        const hmodRAM = statusNode[name]["memoryHmodK"].as!ulong;

        if(!errors.empty) { errorsCount += 1; }
        statuses[name] = DocsStatus(errors, didGenerate, hmodRAM);
    }
    if(errorsCount > 0)
    {
        context.writeln((errorsCount == versions.length ? "" : "PARTIALLY ") ~
                        "FAILED to generate documentation for ", pkgName);
    }

    return true;
}

/** Get package data for all packages.
 *
 * Package data is loaded from cache (`packagedata.yaml` by default) if the package has
 * not changed, or otherwise loaded from the package page at `code.dlang.org`.
 *
 * Params:
 *
 * config  = Config to get cached versions path from.
 * context = Context for output.
 *
 * Returns: Package data indexed by package name.
 *
 * Throws:  Exception on failure.
 */
Package[string] getPackageData(ref const Config config, ref Context context)
{
    auto timer = Timer("Getting package data", context);

    // Get package/version info and cache it on success.
    import std.net.curl;
    context.writeHeading("Getting package list");
    const packagesHtmlPath = "http://code.dlang.org";
    PackageRow[string] packageRows;
    try
    {
        packageRows = parsePackageList(cast(string)get(packagesHtmlPath), context);
    }
    catch(Exception e)
    {
        context.writeln("ERROR: Failed to get package list from %s. "
                        "Maybe the format has changed?: %s ", packagesHtmlPath, e.msg);
        throw e;
    }
    scope(success) { savePackageList(config, context, packageRows); }

    PackageRow[string] packageListPrevious;
    Package[string] packageDataPrevious;
    if(!config.forceInfoRefresh)
    {
        packageListPrevious = loadPackageList(config, context);
        packageDataPrevious = loadPackageData(config, context);
    }

    context.writeHeading("Updating package data");
    string packageDataHtmlPath;
    Package[string] packageData;
    try foreach(name, row; packageRows)
    {
        string note = "reloaded";
        // Once we load versions for the package, either from cache or web, determine
        // version types and print the versions.
        scope(success)
        {
            packageData[name].row = row;
            packageData[name].versions.initVersionTypes();
            context.writefln("%s: %s (%s)", name,
                             packageData[name].versions.map!(v => v.name).joiner(", "), note);
        }

        stdout.flush();
        if(name in packageListPrevious && row == packageListPrevious[name])
        {
            packageData[name] = packageDataPrevious[name];
            note = "cached";
            continue;
        }

        packageDataHtmlPath = "http://code.dlang.org/packages/" ~ name;
        string packageHtml;
        import std.net.curl;
        try { packageHtml = cast(string)get(packageDataHtmlPath); }
        catch(CurlException e)
        {
            context.writefln("WARNING: Failed to get %s: %s; Ignoring", packageDataHtmlPath, e.msg);
            continue;
        }

        packageData[name] = parsePackageData(packageHtml, name);
    }
    catch(Exception e)
    {
        context.writeln("ERROR: Failed to get package information from %s. "
                        "Maybe the format has changed?: %s ", packageDataHtmlPath, e.msg);
        throw e;
    }
    return packageData;
}

/// Package info from the front page of `code.dlang.org`.
struct PackageRow
{
    /// Latest version of the package.
    string latestVersion;
    /// Date of last change to the package.
    string date;
    /// Description text of the package.
    string description;
}

/// All data known about a package.
struct Package
{
    /// See_Also: PackageRow.
    PackageRow row;
    alias row this;
    /// All versions of the package.
    Version[] versions;
}

/// Documentation generation status (for one version of one package).
struct DocsStatus
{
    /// All errors encountered if doc generation has failed.
    string[] errors;
    /// Did we actually generate documentation (as opposed to failing or skipping)?
    bool didGenerateDocs;
    /// Peak RAM usage of the `hmod` process used to generate the documentation.
    ulong hmodRAM;
}

import semver;
/// One version of a package. Used in arrays of all versions of a package.
struct Version
{
    /// Version name, e.g. `"0.2.3"` or `""~master"`.
    string name;
    /// Version type. Initialized with `initVersionTypes`.
    VersionType type = VersionType.UNINITIALIZED;

    // Used by initVersionTypes to determine version types.
    private SemVer semver = SemVer("");

    /** Ctor that version name, but not type.
     *
     * `initVersionTypes` must be called to complete initialization.
     */
    this(string name) { this.name = name; semver = SemVer(name); }

    /// Is this version uninitialized? Both name and type must be set in an initialized version.
    bool isNull() const { return type == VersionType.UNINITIALIZED; }
}

/** Possible version types.
 *
 * We use this to highlight different versions, determine if we need browsable docs or
 * just archives, etc.
 */
enum VersionType: ubyte
{
    /// Default value, before version type is determined.
    UNINITIALIZED,
    /// Latest stable version of a package.
    Latest,
    /// Latest version of an old *minor version* (e.g. latest 2.4.x if we also have a 2.5.x).
    LatestOldMinor,
    /// Latest pre-release version.
    Prerelease,
    /// Obsolete pre-release version.
    PrereleaseObsolete,
    /// Obsolete stable version, surpassed by the Latest or LatestOldMinor version.
    Obsolete,
    /// The `~master` branch.
    BranchMaster,
    /// Any non-`~master` branch.
    Branch,
}

/** Get the latest **stable** version, given all versions of a package.
 *
 * Returns: The latest stable version, or an uninitialized version if not found.
 *
 */
const(Version) latestVersion(const Version[] versions)
{
    auto found = versions.find!(v => v.type == VersionType.Latest);
    return found.empty ? Version.init : found.front;
}

/** Initialize version types, given all versions of a package.
 *
 * All versions are needed to determine which is the latest stable version, latest
 * pre-release, which version are obsolete and so on.
 *
 * Params:
 *
 * versions = All versions of a package. The `type` member of each version will be
 *            modified.
 */
void initVersionTypes(Version[] versions)
{
    // First assign 'branch' version types to versions that are not in semver format
    // (versions are either semver or ~branch)
    foreach(ref ver; versions) if(!ver.semver.isValid)
    {
        ver.type = ver.name == "~master" ? VersionType.BranchMaster : VersionType.Branch;
    }
    //TODO can be simplified, especially with new groupBy/chunkBy/whatever it's called.
    // Used with std.algorithm.minPos to get the *maximum* Version ordered by semver.
    bool maxSemver(ref Version a, ref Version b) { return a.semver > b.semver; }
    // isNull is true as long as type is not initialized.
    // Process by groups of versions with the same major and minor version numbers.
    while(versions.canFind!((ref v) => v.isNull))
    {
        auto nullVers = versions.filter!((ref v) => v.isNull);
        assert(!nullVers.canFind!((ref v) => !v.semver.isValid), "Invalid semver of null version");
        auto first = nullVers.front.semver;
        bool sameMinor(ref SemVer v)
        {
            return v == first ||
                   !only(VersionPart.MAJOR, VersionPart.MINOR).canFind(v.differAt(first));
        }
        // Versions with same major/minor numbers as "first".
        auto group = nullVers.filter!((ref v) => sameMinor(v.semver));
        auto stable   = group.filter!((ref v) => v.semver.isStable);
        auto unstable = group.filter!((ref v) => !v.semver.isStable);

        // Get the max stable/unstable versions and set their types.
        // All LatestOldMinor versions will later be compared to get the Latest.
        if(!stable.empty)   { stable.minPos!maxSemver.front.type = VersionType.LatestOldMinor; }
        if(!unstable.empty) { unstable.minPos!maxSemver.front.type = VersionType.Prerelease; }

        foreach(ref v; stable.filter!(v => v.isNull))   { v.type = VersionType.Obsolete; }
        foreach(ref v; unstable.filter!(v => v.isNull)) { v.type = VersionType.PrereleaseObsolete; }
    }

    auto stableLatest = versions.filter!((ref v) => v.type == VersionType.LatestOldMinor);
    if(!stableLatest.empty) { stableLatest.minPos!maxSemver.front.type = VersionType.Latest; }
}

/** Parse package info in a the main HTML page of `code.dlang.org`.
 *
 * Params:
 *
 * htmlSource = HTML to get package info from.
 * context    = Context for output messages.
 *
 * Note: must be kept in sync with the main `code.dlang.org` page or API.
 *
 * Returns: Parsed package info.
 */
PackageRow[string] parsePackageList(string htmlSource, ref Context context)
{
    auto timer = Timer("Getting package info", context);
    import std.regex;
    htmlSource = htmlSource.splitLines.join;
    auto tables = htmlSource.matchAll(`<table>.*?</table>`);

    import std.exception;
    // Shortcut alias so we don't always fo enforce(blah, new Exception("blah"))
    alias enforceE = enforceEx!Exception;
    enforceE(tables.walkLength == 1, "Not exactly 1 <table>");

    string table = tables.front.hit;
    auto rows = table.matchAll(`<tr>.*?</tr>`);

    // As of January 2014 there are >400 packages at code.dlang.org. If there are any
    // less, there has been a change in format and we need to rewrite parsePackages().
    enforceE(rows.walkLength > 400, "Unexpected number of <tr>");
    rows.popFront();

    PackageRow[string] result;
    foreach(rowStr; rows.map!(r => r.hit))
    {
        auto cols = rowStr.matchAll(`<td(?: class="[\w\s-_]+")?>.*?</td>`);
        enforceE(cols.walkLength == 4, "Not exactly 4 <td> in a <tr>");

        auto nameMatch = cols.front.hit.matchAll(`<a href=".*?">(?P<name>.*?)</a>`);
        enforceE(nameMatch.walkLength == 1, "Not exactly 1 <a> in a package column");
        cols.popFront();
        auto versionMatch = cols.front.hit.matchAll(`<td class="nobreak">(?P<version>.*?)</td>`);
        enforceE(versionMatch.walkLength == 1, "Not exactly 1 version match in a package column");
        cols.popFront();
        auto dateMatch = cols.front.hit.matchAll(`<td class="nobreak">(?P<date>.*?)</td>`);
        enforceE(dateMatch.walkLength == 1, "Not exactly 1 date match in a package column");
        cols.popFront();
        auto descriptionMatch = cols.front.hit.matchAll(`<td>(?P<description>.*?)</td>`);
        enforceE(descriptionMatch.walkLength == 1, "Not exactly 1 description match in a package column");

        string name        = nameMatch.front["name"];
        string semver      = versionMatch.front["version"];
        string date        = dateMatch.front["date"];
        string description = descriptionMatch.front["description"];

        result[name] = PackageRow(semver, date, description);
    }

    return result;
}


/** Parse data from a package HTML page from `code.dlang.org`.
 *
 * Params:
 *
 * htmlSource  = HTML to get version info from.
 * packageName = Name of the package.
 *
 * Note: must be kept in sync with `code.dlang.org` package page or API.
 *
 * Returns: Package data in a Package struct, which **needs further initialization**.
 *          The `row` member must be set, and `initVersionTypes()` must be called on the
 *          `versions` member to fully initialize version info.
 */
Package parsePackageData(string htmlSource, string packageName)
{
    import std.regex;
    htmlSource = htmlSource.splitLines.join;
    auto versionsMatch = htmlSource.matchAll(`<h2>Available versions</h2>(?P<versions>.*?)</div>`);

    import std.exception;
    // Shortcut alias so we don't always fo enforce(blah, new Exception("blah"))
    alias enforceE = enforceEx!Exception;
    enforceE(versionsMatch.walkLength == 1, "Not exactly 1 'versions' match");

    auto versions = versionsMatch.front["versions"];

    // The current version is not wrapped in a link, as the package page is viewing it.
    auto currentVerMatch = versions.matchAll(`<em>(?P<current>.*?)</em>`);
    enforceE(currentVerMatch.walkLength == 1, "Not exactly 1 current version match");

    auto olderVerMatch = versions.matchAll
        (`<a href="../packages/%s/(?P<version1>.*?)">(?P<version2>.*?)</a>`.format(packageName));

    foreach(match; olderVerMatch)
    {
        enforceE(match["version1"] == match["version2"],
                 "Version link does not match version name");
    }

    auto current = currentVerMatch.front["current"];

    Package result;
    result.versions = Version(current) ~ olderVerMatch.map!(m => Version(m["version2"])).array;
    return result;
}

/** Save package list so we can compare what has changed next time `ddocs.org` runs.
 *
 * Params:
 *
 * config      = Config to get package list file path.
 * context     = Context for output.
 * packageRows = Package list to save.
 */
void savePackageList(ref const Config config, ref Context context,
                     const PackageRow[string] packageRows)
{
    context.writeln("Saving package information");

    import yaml;
    Node[string] pkgNodes;
    foreach(name, row; packageRows)
    {
        pkgNodes[name] = Node(["latestVersion": row.latestVersion,
                               "date": row.date,
                               "description": row.description]);
    }
    try { Dumper(config.packagesListPath).dump(Node(pkgNodes)); }
    catch(YAMLException e)
    {
        context.writefln("WARNING: failed to save (cache) package list: %s. Ignoring.", e.msg);
    }
}

/** Load cached package list (from `packagelist.yaml` by default).
 *
 * Params:
 *
 * config  = Config to get package list file path.
 * context = Context for output/logging.
 *
 * Returns: Package rows with cached package information, indexed by package name.
 */
PackageRow[string] loadPackageList(ref const Config config, ref Context context)
{
    context.writeln("Loading cached package list");
    PackageRow[string] packageRows;
    import yaml;
    try foreach(string name, ref Node pkg; Loader(config.packagesListPath).load())
    {
        packageRows[name] = PackageRow(pkg["latestVersion"].as!string,
                                       pkg["date"].as!string,
                                       pkg["description"].as!string);
    }
    catch(YAMLException e)
    {
        context.writefln("WARNING: failed to load (cached) package list: %s. Ignoring.", e.msg);
        return null;
    }
    return packageRows;
}

/** Save detailed package data so we don't need to crawl `code.dlang.org` every time for it.
 *
 * Params:
 *
 * config  = Config to get versions file path.
 * context = Context with version information.
 */
void savePackageData(ref const Config config, ref Context context)
{
    import yaml;
    context.writeln("Saving package version information");
    try
    {
        Dumper(config.packageDataPath).dump(
            Node(context.packageData.keys,
                 context.packageData
                        .byValue
                        .map!(p => Node(["versions" : p.versions.map!(v => v.name).array]))
                        .array));
    }
    catch(YAMLException e)
    {
        context.writefln("WARNING: failed to save (cache) detailed package data: %s. Ignoring.", e.msg);
    }
}

/** Load cached detailed package data (from `packagedata.yaml` by default).
 *
 * Params:
 *
 * config  = Config to get the path to read from.
 * context = Context for output/logging.
 *
 * Returns: Loaded package data. Only partially initialized; the `row` members must be set
 *          and `initVersionTypes()` must be called on the `version` members to set
 *          version types.
 */
Package[string] loadPackageData(ref const Config config, ref Context context)
{
    context.writeln("Loading cached detailed package information");
    Package[string] packages;
    import yaml;
    try foreach(string name, ref Node node; Loader(config.packageDataPath).load())
    {
        Package pkg;
        pkg.versions = node["versions"].as!(Node[]).map!((ref n) => Version(n.as!string)).array;
        packages[name] = pkg;
    }
    catch(YAMLException e)
    {
        context.writefln("WARNING: failed to load (cached) detailed package data: %s. Ignoring.", e.msg);
        return null;
    }
    return packages;
}


/// A multi-argument wrapper for `put()` that calls `put()` for every argument in `args`.
void putAll(R, S...)(ref R dst, S args)
{
    foreach(arg; args) { dst.put(arg); }
}

/** An RAII struct that measures time spent in a scope and writes the resulting time to stdout.
 */
struct Timer
{
private:
    // Time when the Timer was constructed.
    ulong startTime_ = ulong.max;
    // Name of the timer, for the result message.
    string name_;
    // Context, used to write the result message both to stdout and the log.
    Context* context_;
    import std.datetime;

public:
    @disable this();

    /** Construct a Timer and start timing.
     *
     * Params:
     *
     * name = Description of what we're timing, for the result message.
     * context = Context used to write the result message to both stdout and the log.
     */
    this(string name, ref Context context)
    {
        context_ = &context;
        name_ = name;
        startTime_ = Clock.currStdTime;
    }

    /// Time since the Timer started in seconds.
    double ageSeconds()
    {
        return (Clock.currStdTime - startTime_) / 10_000_000.0;
    }

    /// Destroy the Timer and write the result message.
    ~this()
    {
        if(startTime_ == ulong.max) { return; }
        context_.writefln("Timer: %s took %.2fs", name_, ageSeconds());
        startTime_ = ulong.max;
    }
}

//TODO DUB package, along with freeSpaceGiB. Something like 'os-info-utils'?
// (but document: only implemented for Linux atm)
/** Get the maximum memory usage this process has had so far, in kiB.
 *
 * Note: does not take swap udage into account.
 *
 * Returns: Peak memory usage on success, 0 on failure. or on plat
 */
ulong peakMemoryUsageK()
{
    version(linux)
    {
        try
        {
            import std.exception;
            auto line = File("/proc/self/status").byLine().filter!(l => l.startsWith("VmHWM"));
            enforce(!line.empty, new Exception("No VmHWM in /proc/self/status"));
            return line.front.split()[1].to!ulong;
        }
        catch(Exception e)
        {
            writeln("Failed to get peak memory usage: ", e);
            return 0;
        }
    }
    else static assert(false, "peakMemoryUsageK not implemented on non-Linux platforms");
}

/** Get free space in the current working directory in GiB.
 *
 * Note: Not useful if writing to a different partition.
 *
 * Throws: ErrnoException on failure.
 */
double freeSpaceGiB()
{
    import core.sys.posix.sys.statvfs;
    import std.exception: errnoEnforce;

    statvfs_t info;
    errnoEnforce(statvfs(".".absolutePath.toStringz, &info) == 0,
                 "Failed to determine free space");
    return (info.f_bsize * info.f_bfree) / 1000_000_000.0;
}


immutable string mainDescription   = import("main-description.md");
immutable string projectDevelopers = import("project-developers.md");
immutable string ddocsOrgCSS       = import("style-ddocs.org.css");
immutable string faviconData       = import("favicon.png");
