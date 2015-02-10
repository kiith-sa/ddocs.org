## For project developers

DDocs.org uses [`harbored-mod`](https://github.com/kiith-sa/harbored-mod) to generate
documentation. It parses D documentation comments as both
[DDoc](http://dlang.org/ddoc.html) and [Markdown](http://en.wikipedia.org/wiki/Markdown)
(except a few [Markdown
 features](https://github.com/kiith-sa/harbored-mod#differences-from-vanilla-markdown)
 incompatible with DDoc).  It is also possible to use DDoc only, see below.


To tweak the documentation generated for your project:

* Add a file called `hmod.cfg` to your project. You can find a basic `hmod.cfg`
  [here](https://github.com/kiith-sa/harbored-mod/blob/master/strings/hmod.cfg) 
  or generate it using `harbored-mod`.

* By default, DDocs.org looks for source directories to document in the `dub.json` file of
  your project. Use the `source` and `exclude` options in `hmod.cfg` to change this:

  ```
  source=./source            # source directory
  source=./subproject/source # another source directory
  exclude=mypackage.hidden   # exclude a module/package
  exclude=mypackage.hidden2  # exclude another module
  ```

* Additional options that may be useful:

  ```
  toc-additional=links.md # file with additional table of
                          # contents content (e.g. links)
  macros=macros.dd        # file with DDoc macros to use
  no-markdown=true        # disable Markdown support
                          # if you only want DDoc
  ```
