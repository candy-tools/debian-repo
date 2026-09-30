# candy-tools Debian repository — local builds through the gh-action-debian-repo
# engine (https://github.com/andresbott/gh-action-debian-repo). This repository
# is an engine *instance* (packages/, debs/, conf/); every target is the
# engine's, run against it — `make help` lists them. The exact CI build:
#   make publish verify-site serve     -> _site/, served at http://localhost:8000
#
# The engine is cloned at ENGINE_REF into .engine/ on first use, so local builds
# run the version CI does: keep ENGINE_REF in step with the `uses:` ref in
# .github/workflows/publish.yml. To run your own engine checkout instead:
#   make publish ENGINE_DIR=../gh-action-debian-repo

ENGINE_REF ?= v1.0.0-rc.2
ENGINE_DIR ?= .engine/$(ENGINE_REF)

ifeq ($(wildcard $(ENGINE_DIR)/Makefile),)
$(info >> fetching the engine $(ENGINE_REF) into $(ENGINE_DIR))
$(shell git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$(ENGINE_REF)" https://github.com/andresbott/gh-action-debian-repo.git "$(ENGINE_DIR)")
endif
include $(ENGINE_DIR)/Makefile
