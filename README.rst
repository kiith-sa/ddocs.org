=========
DDocs.org
=========

------------
Introduction
------------

This is the implementation of the `DDocs.org <http://ddocs.org>`_ documentation
repository for D projects. In short, it fetches `dub <http://code.dlang.org>`_
packages, generates documentation for them using `harbored-mod
<https://github.com/kiith-sa/harbored-mod>`_ and `hmod-dub
<https://github.com/kiith-sa/hmod-dub>`_, and generates simple pages listing the
packages and documentation archives.

**Principles**:

* **No dynamic content**: DDocs.org is a static content generator; it generates HTML that
  can be directly served, without any generation on-the-fly.
* **JavaScript is optional**: If something can be implemented without JavaScript, it
  should be implemented without JavaScript. If it cannot be implemented without JavaScript
  (e.g. search), it must be optional. JavaScript code **must not be pulled** from an
  outside source.


------------
Requirements
------------

To run, ``ddocs.org`` needs ``hmod-dub``, ``hmod`` (`harbored-mod
<https://github.com/kiith-sa/harbored-mod>`_) and ``dub`` to be installed
(available in ``PATH``).


-----
Usage
-----

See the help string::

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
       -P, --packages-list-path PATH   Path to a YAML file where information
                                       about known packages is stored. Will be
                                       updated with any new package information.
                                       Will be created if it doesn't exist.
                                       Default: ./packages.yaml
       -v, --versions-list-path PATH   Path to a YAML file where information
                                       about known package versions is stored.
                                       Helps minimize dub registry page downloads.
                                       Will be updated with any new version
                                       information. Will be created if it doesn't
                                       exist.
                                       Default: ./versions.yaml
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


-------------------
Directory structure
-------------------

===============  =======================================================================
Directory        Contents
===============  =======================================================================
``./``           This README, license, dub config, etc.
``./source``     Source code.
``./strings``    Files imported directly into the DDocs.org binary.
===============  =======================================================================


-------
License
-------


DDocs.org is released under the terms of the `Boost Software License 1.0
<http://www.boost.org/LICENSE_1_0.txt>`_.  This license allows you to use the
source code in your own projects, open source or proprietary, and to modify it
to suit your needs.  However, in source distributions, you have to preserve the
license headers in the source code and the accompanying license file.

Full text of the license can be found in file ``LICENSE_1_0.txt`` and is also
displayed here::

    Boost Software License - Version 1.0 - August 17th, 2003

    Permission is hereby granted, free of charge, to any person or organization
    obtaining a copy of the software and accompanying documentation covered by
    this license (the "Software") to use, reproduce, display, distribute,
    execute, and transmit the Software, and to prepare derivative works of the
    Software, and to permit third-parties to whom the Software is furnished to
    do so, all subject to the following:

    The copyright notices in the Software and this entire statement, including
    the above license grant, this restriction and the following disclaimer,
    must be included in all copies of the Software, in whole or in part, and
    all derivative works of the Software, unless such copies or derivative
    works are solely in the form of machine-executable object code generated by
    a source language processor.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
    SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
    FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
    ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
    DEALINGS IN THE SOFTWARE.


-------
Credits
-------

DDocs.org was created by Ferdinand Majerech aka Kiith-Sa kiithsacmp[AT]gmail.com,
using Vim and DMD on Linux Mint.

See more `D <http://www.dlang.org>`_ projects at `code.dlang.org
<http://code.dlang.org>`_.
