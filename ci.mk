# Minimal makefile for Sphinx documentation
#

# You can set these variables from the command line.
SPHINXOPTS    = -n -W
SPHINXBUILD   = sphinx-build
SOURCEDIR     = source
BUILDDIR      = build
current_dir = $(shell pwd)



clean:
	rm -rf build

html:
	sphinx-build -M html \
	source \
 	build \
 	$(SPHINXOPTS)

json:
	sphinx-build -M json \
	-d build/doctrees \
	source \
	build/json \
	$(SPHINXOPTS)
