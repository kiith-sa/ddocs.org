## For project developers

DDocs.org uses [`harbored-mod`](https://github.com/kiith-sa/harbored-mod) to generate
documentation. It parses D documentation comments as both
[DDoc](http://dlang.org/ddoc.html) and [Markdown](http://en.wikipedia.org/wiki/Markdown)
(except a few [Markdown
 features](https://github.com/kiith-sa/harbored-mod#differences-from-vanilla-markdown)
 incompatible with DDoc).  In future it will be possible to disable either format so that
pure DDoc or Markdown may be used.


To tweak the documentation generated for your project:

* Add a file called `hmod.cfg` to your project. You can find a basic `hmod.cfg`
  [here](https://github.com/kiith-sa/harbored-mod/blob/master/strings/hmod.cfg) 
  or generate it using `harbored-mod`.

* By default, DDocs.org looks for source directories to document in the `dub.json` file of
  your project. Use the `source` and `exclude` options in `hmod.cfg` to change this:

  ```
  source=./source                    # a source directory
  source=./subproject/source         # another source directory
  exclude=./source/hidden-module.d   # exclude a module
  exclude=./source/hidden-module2.d  # exclude another module
  ```

* Additional options that may be useful:

  ```
  toc-additional=links.md  # a file with additional content for
                           # the table of contents (e.g. links)
  macros=macros.dd         # a file with user-defined DDoc macros to use
  ```
