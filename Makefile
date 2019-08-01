# Setup variables for the Makefile
NAME := kubedrainer
PKG := github.com/VirtusLab/$(NAME)
REPO := virtuslab/$(NAME)
DOCKER_REGISTRY := quay.io

# Set POSIX sh for maximum interoperability
SHELL := /bin/sh
PATH  := $(GOPATH)/bin:$(PATH)

# Set an output prefix, which is the local directory if not specified
PREFIX?=$(shell pwd)

# Set the main.go path for go command
BUILD_PATH := ./cmd/$(NAME)

# Set any default go build tags
BUILDTAGS :=

# Set the build dir, where built cross-compiled binaries will be output
BUILDDIR := ${PREFIX}/cross

# Populate version variables
# Add to compile time flags
VERSION := $(shell cat VERSION.txt)
GITCOMMIT := $(shell git rev-parse --short HEAD)
GITUNTRACKEDCHANGES := $(shell git status --porcelain --untracked-files=no)
GITIGNOREDBUTTRACKEDCHANGES := $(shell git ls-files -i --exclude-standard)
ifneq ($(GITUNTRACKEDCHANGES),)
    GITCOMMIT := $(GITCOMMIT)-dirty
endif
ifneq ($(GITIGNOREDBUTTRACKEDCHANGES),)
    GITCOMMIT := $(GITCOMMIT)-dirty
endif

VERSION_TAG := $(VERSION)-$(GITCOMMIT)
LATEST_TAG := latest

CTIMEVAR=-X $(PKG)/version.GITCOMMIT=$(GITCOMMIT) -X $(PKG)/version.VERSION=$(VERSION)
GO_FLAGS=-mod=vendor -ldflags "-w $(CTIMEVAR)"
GO_FLAGS_STATIC=-mod=vendor -ldflags "-w $(CTIMEVAR) -extldflags -static"

# List the GOOS and GOARCH to build
GOOSARCHES = darwin/amd64 linux/arm linux/arm64 linux/amd64 windows/amd64

PACKAGES = $(shell go list -f '{{.ImportPath}}/' ./... | grep -v vendor)

ARGS ?= $(EXTRA_ARGS)

.DEFAULT_GOAL := help

.PHONY: all
all: clean mod verify build docker-build ## Ensure deps, test, verify, docker build
	@echo "+ $@"

.PHONY: init
init: ## Initializes this Makefile dependencies: dep, golint, staticcheck, checkmake
	@echo "+ $@"
	go get -u golang.org/x/lint/golint
	go get -u honnef.co/go/tools/cmd/staticcheck
	go get -u golang.org/x/tools/cmd/goimports
	go get -u github.com/mrtazz/checkmake
	go get -u github.com/jessfraz/junk/sembump

.PHONY: mod
mod: ## Populates the vendor directory with dependencies
	@echo "+ $@"
	go mod tidy
	go mod vendor

.PHONY: build
build: $(NAME) ## Builds a dynamic executable or package
	@echo "+ $@"

$(NAME): $(wildcard *.go) $(wildcard */*.go) VERSION.txt
	@echo "+ $@"
	go build -tags "$(BUILDTAGS)" ${GO_FLAGS} -o $(NAME) $(BUILD_PATH)

.PHONY: static
static: ## Builds a static executable
	@echo "+ $@"
	CGO_ENABLED=0 go build \
				-tags "$(BUILDTAGS) static_build" \
				${GO_FLAGS_STATIC} -o $(NAME) $(BUILD_PATH)

.PHONY: fmt
fmt: ## Verifies all files have been `gofmt`ed
	@echo "+ $@"
	@go fmt $(PACKAGES)

.PHONY: lint
lint: ## Verifies `golint` passes
	@echo "+ $@"
	@golint -set_exit_status $(PACKAGES)

.PHONY: goimports
goimports: ## Verifies `goimports` passes
	@echo "+ $@"
	@goimports -l -e $(shell find . -type f -name '*.go' -not -path "./vendor/*")

.PHONY: test
test: ## Runs the go tests
	@echo "+ $@"
	@RUNNING_TESTS=1 go test -v -tags "$(BUILDTAGS) cgo" $(PACKAGES)

.PHONY: vet
vet: ## Verifies `go vet` passes
	@echo "+ $@"
	@go vet $(PACKAGES)

.PHONY: staticcheck
staticcheck: ## Verifies `staticcheck` passes
	@echo "+ $@"
	@staticcheck $(PACKAGES)

.PHONY: verify
verify: fmt lint vet staticcheck goimports test ## Runs a fmt, lint, vet, staticcheck, goimports and test

.PHONY: cover
cover: ## Runs go test with coverage
	@echo "" > coverage.txt
	@for d in $(PACKAGES); do \
		RUNNING_TESTS=1 go test -race -coverprofile=profile.out -covermode=atomic "$$d"; \
		if [ -f profile.out ]; then \
			cat profile.out >> coverage.txt; \
			rm profile.out; \
		fi; \
	done;

.PHONY: install
install: ## Installs the executable
	@echo "+ $@"
	go install -tags "$(BUILDTAGS)" ${GO_FLAGS} $(BUILD_PATH)

.PHONY: run
run: ## Run the executable, you can use EXTRA_ARGS
	@echo "+ $@"
	go run -tags "$(BUILDTAGS)" ${GO_FLAGS} $(BUILD_PATH)/main.go $(ARGS)

define buildrelease
GOOS=$(1) GOARCH=$(2) CGO_ENABLED=0 go build \
	 -o $(BUILDDIR)/$(NAME)-$(1)-$(2) \
	 -a -tags "$(BUILDTAGS) static_build netgo" \
	 -installsuffix netgo ${GO_FLAGS_STATIC} $(BUILD_PATH);
md5sum $(BUILDDIR)/$(NAME)-$(1)-$(2) > $(BUILDDIR)/$(NAME)-$(1)-$(2).md5;
sha256sum $(BUILDDIR)/$(NAME)-$(1)-$(2) > $(BUILDDIR)/$(NAME)-$(1)-$(2).sha256;
endef

.PHONY: release
release: $(wildcard *.go) $(wildcard */*.go) VERSION.txt ## Builds the cross-compiled binaries, naming them in such a way for release (eg. binary-GOOS-GOARCH)
	@echo "+ $@"
	$(foreach GOOSARCH,$(GOOSARCHES), $(call buildrelease,$(subst /,,$(dir $(GOOSARCH))),$(notdir $(GOOSARCH))))

.PHONY: clean
clean: ## Cleanup any build binaries or packages
	@echo "+ $@"
	$(RM) $(NAME) || echo "Couldn't delete, not there."
	$(RM) test$(NAME) || echo "Couldn't delete, not there."
	$(RM) -r $(BUILDDIR) || echo "Couldn't delete, not there."
	$(RM) coverage.txt || echo "Couldn't delete, not there."

.PHONY: docker-build
docker-build: ## Build the container
	@echo "+ $@"
	docker build -t $(REPO):$(GITCOMMIT) .

.PHONY: docker-login
docker-login: ## Log in into the repository
	@echo "+ $@"
	@docker login -u="${DOCKER_USER}" -p="${DOCKER_PASS}" $(DOCKER_REGISTRY)

.PHONY: docker-images
docker-images: ## List all local containers
	@echo "+ $@"
	@docker images

.PHONY: docker-push
docker-push: ## Push the container
	@echo "+ $@"
	@docker tag $(REPO):$(GITCOMMIT) $(DOCKER_REGISTRY)/$(REPO):$(VERSION)
	@docker tag $(REPO):$(GITCOMMIT) $(DOCKER_REGISTRY)/$(REPO):$(VERSION_TAG)
	@docker tag $(REPO):$(GITCOMMIT) $(DOCKER_REGISTRY)/$(REPO):$(LATEST_TAG)
	@docker push $(DOCKER_REGISTRY)/$(REPO):$(VERSION)
	@docker push $(DOCKER_REGISTRY)/$(REPO):$(VERSION_TAG)
	@docker push $(DOCKER_REGISTRY)/$(REPO):$(LATEST_TAG)

.PHONY: bump-version
BUMP := patch
bump-version: ## Bump the version in the version file. Set BUMP to [ patch | major | minor ]
	@echo "+ $@"
	$(eval NEW_VERSION=$(shell sembump --kind $(BUMP) $(VERSION)))
	@echo "Bumping VERSION.txt from $(VERSION) to $(NEW_VERSION)"
	@echo $(NEW_VERSION) > VERSION.txt
	@echo "Updating version from $(VERSION) to $(NEW_VERSION) in README.md"
	sed -i s/$(VERSION)/$(NEW_VERSION)/g README.md
	sed -i s/$(VERSION)/$(NEW_VERSION)/g internal/version/version.go
	git add VERSION.txt README.md internal/version/version.go
	git commit -vseam "Bump version to $(NEW_VERSION)"
	@echo "Run make tag to create and push the tag for new version $(NEW_VERSION)"

.PHONY: tag
tag: ## Create a new git tag to prepare to build a release
	@echo "+ $@"
	git tag -a $(VERSION) -m "$(VERSION)"
	git push origin $(VERSION)

.PHONY: status
status: ## Shows general status
	@echo "+ $@"
	@echo "Commit: $(GITCOMMIT), VERSION: $(VERSION)"
	@echo
ifneq ($(GITUNTRACKEDCHANGES),)
	@echo "Changed files:"
	@git status --porcelain --untracked-files=no
	@echo
endif
ifneq ($(GITIGNOREDBUTTRACKEDCHANGES),)
	@echo "Ignored but tracked files:"
	@git ls-files -i --exclude-standard
	@echo
endif

.PHONY: checkmake
checkmake: ## Check this Makefile
	@echo "+ $@"
	@checkmake Makefile

.PHONY: help
help:
	@grep -Eh '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'