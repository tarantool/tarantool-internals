# Minimal makefile for Sphinx documentation
#

# You can set these variables from the command line.
SPHINXOPTS    =
SPHINXBUILD   = sphinx-build
AUTOBUILD     = sphinx-autobuild
SOURCEDIR     = source
BUILDDIR      = build
current_dir = $(shell pwd)

# Put it first so that "make" without argument is like "make help".
help:
	@$(SPHINXBUILD) -M help "$(SOURCEDIR)" "$(BUILDDIR)" $(SPHINXOPTS) $(O)

autobuild:
	docker run --rm -it -p 8000:8000 -v $(current_dir):/doc tarantool/doc-builder:slim-4.2 sh -c \
    "$(AUTOBUILD) -b dirhtml --host 0.0.0.0 --port 8000 $(SOURCEDIR) $(BUILDDIR) $(SPHINXOPTS) $(O)"


.PHONY: help Makefile
	docker run --rm -it -v $(current_dir):/doc tarantool/doc-builder:slim-4.2 sh -c "$(SPHINXBUILD) -M $@ $(SOURCEDIR) $(BUILDDIR) $(SPHINXOPTS) $(O)"

# Catch-all target: route all unknown targets to Sphinx using the new
# "make mode" option.  $(O) is meant as a shortcut for $(SPHINXOPTS).
%: Makefile
	docker run --rm -it -v $(current_dir):/doc tarantool/doc-builder:slim-4.2 sh -c "$(SPHINXBUILD) -M $@ $(SOURCEDIR) $(BUILDDIR) $(SPHINXOPTS) $(O)"
