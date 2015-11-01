#!/usr/bin/rdmd

module ddocs.org.buffered;

import std.algorithm;
import std.file;
import std.path: buildPath;
import std.stdio;
import std.string;

auto helpString = q"(
-------------------------------------------------------------------------------
ddocs.org.buffered
Runs ddocs.org in a double-buffered manner.
Copyright (C) 2015 Ferdinand Majerech

Usage: ddocs.org.buffered RESULT WORK [DDOCS.ORG-OPTIONS]

ddocs.org.buffered runs `ddocs.org`, writing output to the WORK/public
directory and then switches RESULT and WORK directories. DDOCS.ORG-OPTIONS are
passed to `ddocs.org`.
-------------------------------------------------------------------------------
)";

int main(string[] args)
{
    if(args.length < 2)
    {
        writeln("Need at least 2 arguments");
        writeln(helpString);
        return 0;
    }

    const resultPath = args[1];
    const workPath   = args[2];
    const ddocsArgs = args[3 .. $];

    const tempPath = resultPath ~ ".tmp";
    // if tempPath exists, we've probably crashed in the middle of a previous exchange.
    // Abort to avoid any more damage.
    if(tempPath.exists)
    {
        writeln("TEMP PATH '" ~ tempPath ~ "' EXISTS: LEFTOVER FROM PREVIOUS FAILURE? ABORTING");
        return 1;
    }

    try
    {
        writeln("ddocs.org.buffered: Ensuring the result/work paths exist");
        if(!resultPath.exists) { mkdirRecurse(resultPath); }
        if(!workPath.exists)   { mkdirRecurse(workPath); }

        // Also ensure there's a directory to copy the complete log to.
        const workLogPath = workPath.buildPath("logs");
        if(!workLogPath.exists) { mkdirRecurse(workLogPath); }
    }
    catch(Exception e)
    {
        writeln("FAILED CREATING PUBLIC AND/OR WORK DIR! ERROR:\n\n", e);
        return 2;
    }


    auto log = File(workPath.buildPath("ddocs.org.buffered.log"), "a");
    void print(S ...)(S args)
    {
        writeln(args);
        log.writeln(args);
    }
    import std.datetime;
    print("---\n", Clock.currTime.toISOExtString(), "\n---");

    import std.process;
    writeln("ddocs.org.buffered: generating documentation");
    const processArgs = "ddocs.org" ~ ddocsArgs;
    writeln(processArgs.map!(a => "'%s'".format(a)).joiner(" "));
    auto pid = spawnProcess(processArgs, stdin, stdout, stderr, null, Config.none, workPath);
    auto status = pid.wait;
    if(status != 0)
    {
        print("FAILED TO GENERATE DOCUMENTATION! STATUS: ", status);
        return 3;
    }

    writeln("ddocs.org.buffered: archiving documentation log");
    import std.datetime;
    const logName = "ddocs.org-log.yaml";
    const logNameXZ = "ddocs.org-log.yaml.xz";
    // Remove the archived log if it a
    const shell = "xz -3f %s && mv %s ./logs/ddocs.org-log.yaml.%s.xz"
                  .format(logName, logNameXZ, Clock.currStdTime);
    writeln(shell);
    pid = spawnShell(shell, stdin, stdout, stderr, null, Config.none, workPath);
    status = pid.wait;
    if(status != 0)
    {
        print("FAILED TO ARCHIVE DOCUMENTATION LOG! STATUS: ", status);
        return 4;
    }

    try
    {
        writeln("ddocs.org.buffered: switching work and result directories");
        resultPath.rename(tempPath);
        workPath.rename(resultPath);
        tempPath.rename(workPath);
    }
    catch(Exception e)
    {
        print("FAILED WORK/RESULT DIRECTORY EXCHANGE! ERROR:\n\n", e);
        return 5;
    }

    return 0;
}
