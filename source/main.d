module app;

import std.algorithm;
import std.array;
import std.typecons;
import std.process;
import std.stdio;
import std.path;
import std.string;
import std.file;
import std.json;

import dido.app;
import dido.config;

void usage()
{
    writefln("Dido: a text editor for D projects.");
    writefln("usage: dido <dub.json>");
    writefln("");
    writefln("-h / --help: show this help");
    writefln("<dub.json>: add this DUB project");
}

void main(string[] args)
{
    try
    {

        string[] dubFiles;
        bool showHelp = false;

        // parse arguments
        for (int i = 1; i < cast(int)(args.length); ++i)
        {
            string arg = args[i];
            if (arg == "-h" || arg == "--help")
            {
                showHelp = true;
            }
            else
            {
                dubFiles ~= args[i];
            }
        }

        if (showHelp)
        {
            usage();
            return;
        }

        if (dubFiles.length == 0)
        {
            dubFiles ~= ".";
        }

        // make all paths absolute
        for (int i = 0; i < cast(int)(dubFiles.length); ++i)
        {
            dubFiles[i] = buildNormalizedPath(absolutePath(dubFiles[i]));
        }

        // if given directories, find DUB files recursively
        for (int i = 0; i < cast(int)(dubFiles.length); ++i)
        {
            if (std.file.isDir(dubFiles[i]))
            {
                auto newFiles = filter!`endsWith(a.name, "dub.json") || endsWith(a.name, "package.json")`(dirEntries(dubFiles[i], SpanMode.shallow))
                .map!`a.name`.map!`std.path.absolutePath(a)`;
                dubFiles = dubFiles ~ newFiles.array;
            }

        }

        // remove all directories and duplicates
        dubFiles = filter!`!std.file.isDir(a)`(dubFiles).uniq.array;

        // check that there is anything left
        if (dubFiles.length == 0)
        {
            throw new Exception("Didn't found any package.json or dub.json");
        }

        // check file names and that they exist
        for (int i = 0; i < cast(int)(dubFiles.length); ++i)
        {
            string s = baseName(dubFiles[i]);
            if (s != "dub.json" && s != "package.json")
                throw new Exception(format("File '%s' should be named package.json or dub.json"));            

            if (!exists(dubFiles[i]))
                throw new Exception(format("File '%s' does not exist"));
        }

        string[] inputFiles;

        void enumerateProject(string dubFile)
        {
            // change directory
            string oldDir = getcwd();
            chdir(dirName(dubFile));
            scope(exit)
                chdir(oldDir);

            auto dubResult = execute(["dub", "describe", "--nodeps"]);

            if (dubResult.status != 0)
                throw new Exception(format("dub returned %s", dubResult.status));

            JSONValue description = parseJSON(dubResult.output);

            foreach (pack; description["packages"].array())
            {
                string packpath = pack["path"].str;

                foreach (file; pack["files"].array())
                {
                    string filepath = file["path"].str();

					// only add files dido can render
					if (filepath.endsWith(".d") || filepath.endsWith(".json") || filepath.endsWith(".res"))
					{
						inputFiles ~= buildPath(packpath, filepath);
					}
                }
            }
        }

        writefln("Found %s projects:", dubFiles.length);
        foreach(dubFile; dubFiles)
        {
            writefln("- %s", dubFile);
            enumerateProject(dubFile);
        }

        DidoConfig config = new DidoConfig;
        
        auto app = scoped!App(config, inputFiles);
        app.mainLoop();

    }
    catch(Exception e)
    {
        writefln("error: %s", e.msg);
    }
}