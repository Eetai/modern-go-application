# A Self-Documenting Makefile: http://marmelab.com/blog/2016/02/29/auto-documented-makefile.html

OS = $(shell uname | tr A-Z a-z)
export PATH := $(abspath bin/):${PATH}

# Project variables
DOCKER_IMAGE = sagikazarmark/modern-go-application
OPENAPI_DESCRIPTOR_DIR = api/openapi

# Build variables
BUILD_DIR ?= build
VERSION ?= $(shell git describe --tags --exact-match 2>/dev/null || git symbolic-ref -q --short HEAD)
COMMIT_HASH ?= $(shell git rev-parse --short HEAD 2>/dev/null)
DATE_FMT = +%FT%T%z
ifdef SOURCE_DATE_EPOCH
    BUILD_DATE ?= $(shell date -u -d "@$(SOURCE_DATE_EPOCH)" "$(DATE_FMT)" 2>/dev/null || date -u -r "$(SOURCE_DATE_EPOCH)" "$(DATE_FMT)" 2>/dev/null || date -u "$(DATE_FMT)")
else
    BUILD_DATE ?= $(shell date "$(DATE_FMT)")
endif
LDFLAGS += -X main.version=${VERSION} -X main.commitHash=${COMMIT_HASH} -X main.buildDate=${BUILD_DATE}
export CGO_ENABLED ?= 0
ifeq (${VERBOSE}, 1)
ifeq ($(filter -v,${GOARGS}),)
	GOARGS += -v
endif
TEST_FORMAT = short-verbose
endif

# Docker variables
DOCKER_TAG ?= ${VERSION}

# Dependency versions
GOTESTSUM_VERSION = 0.4.0
GOLANGCI_VERSION = 1.21.0
OPENAPI_GENERATOR_VERSION = 4.1.1
PROTOTOOL_VERSION = 1.8.0
GQLGEN_VERSION = 0.10.2
MGA_VERSION = 0.0.13

GOLANG_VERSION = 1.13

# Add the ability to override some variables
# Use with care
-include override.mk

.PHONY: up
up: start config.toml ## Set up the development environment

.PHONY: down
down: clear ## Destroy the development environment
	docker-compose down --volumes --remove-orphans --rmi local
	rm -rf var/docker/volumes/*

.PHONY: reset
reset: down up ## Reset the development environment

.PHONY: clear
clear: ## Clear the working area and the project
	rm -rf bin/

docker-compose.override.yml:
	cp docker-compose.override.yml.dist docker-compose.override.yml

.PHONY: start
start: docker-compose.override.yml ## Start docker development environment
	@ if [ docker-compose.override.yml -ot docker-compose.override.yml.dist ]; then diff -u docker-compose.override.yml docker-compose.override.yml.dist || (echo "!!! The distributed docker-compose.override.yml example changed. Please update your file accordingly (or at least touch it). !!!" && false); fi
	docker-compose up -d

.PHONY: stop
stop: ## Stop docker development environment
	docker-compose stop

config.toml:
	sed 's/production/development/g; s/debug = false/debug = true/g; s/shutdownTimeout = "15s"/shutdownTimeout = "0s"/g; s/format = "json"/format = "logfmt"/g; s/level = "info"/level = "debug"/g; s/addr = ":10000"/addr = "127.0.0.1:10000"/g; s/httpAddr = ":8000"/httpAddr = "127.0.0.1:8000"/g; s/grpcAddr = ":8001"/grpcAddr = "127.0.0.1:8001"/g' config.toml.dist > config.toml

.PHONY: run-%
run-%: build-%
	${BUILD_DIR}/$*

.PHONY: run
run: $(patsubst cmd/%,run-%,$(wildcard cmd/*)) ## Build and execute a binary

.PHONY: clean
clean: ## Clean builds
	rm -rf ${BUILD_DIR}/
	rm -rf cmd/*/pkged.go

.PHONY: goversion
goversion:
ifneq (${IGNORE_GOLANG_VERSION_REQ}, 1)
	@printf "${GOLANG_VERSION}\n$$(go version | awk '{sub(/^go/, "", $$3);print $$3}')" | sort -t '.' -k 1,1 -k 2,2 -k 3,3 -g | head -1 | grep -q -E "^${GOLANG_VERSION}$$" || (printf "Required Go version is ${GOLANG_VERSION}\nInstalled: `go version`" && exit 1)
endif

.PHONY: build-%
build-%: goversion
ifeq (${VERBOSE}, 1)
	go env
endif

	go build ${GOARGS} -tags "${GOTAGS}" -ldflags "${LDFLAGS}" -o ${BUILD_DIR}/$* ./cmd/$*

.PHONY: build
build: goversion ## Build all binaries
ifeq (${VERBOSE}, 1)
	go env
endif

	@mkdir -p ${BUILD_DIR}
	go build ${GOARGS} -tags "${GOTAGS}" -ldflags "${LDFLAGS}" -o ${BUILD_DIR}/ ./cmd/...

.PHONY: build-release
build-release: $(patsubst cmd/%,cmd/%/pkged.go,$(wildcard cmd/*)) ## Build all binaries without debug information
	@${MAKE} LDFLAGS="-w ${LDFLAGS}" GOARGS="${GOARGS} -trimpath" BUILD_DIR="${BUILD_DIR}/release" build

.PHONY: build-debug
build-debug: ## Build all binaries with remote debugging capabilities
	@${MAKE} GOARGS="${GOARGS} -gcflags \"all=-N -l\"" BUILD_DIR="${BUILD_DIR}/debug" build

bin/pkger:
	@mkdir -p bin
	go build -o bin/pkger github.com/markbates/pkger/cmd/pkger

cmd/%/pkged.go: bin/pkger ## Embed static files
	bin/pkger -o cmd/$*

.PHONY: docker
docker: ## Build a Docker image
	docker build -t ${DOCKER_IMAGE}:${DOCKER_TAG} .
ifeq (${DOCKER_LATEST}, 1)
	docker tag ${DOCKER_IMAGE}:${DOCKER_TAG} ${DOCKER_IMAGE}:latest
endif

.PHONY: docker-debug
docker-debug: ## Build a Docker image with remote debugging capabilities
	docker build -t ${DOCKER_IMAGE}:${DOCKER_TAG}-debug --build-arg BUILD_TARGET=debug .
ifeq (${DOCKER_LATEST}, 1)
	docker tag ${DOCKER_IMAGE}:${DOCKER_TAG}-debug ${DOCKER_IMAGE}:latest-debug
endif

.PHONY: check
check: test-all lint ## Run tests and linters

bin/gotestsum: bin/gotestsum-${GOTESTSUM_VERSION}
	@ln -sf gotestsum-${GOTESTSUM_VERSION} bin/gotestsum
bin/gotestsum-${GOTESTSUM_VERSION}:
	@mkdir -p bin
	curl -L https://github.com/gotestyourself/gotestsum/releases/download/v${GOTESTSUM_VERSION}/gotestsum_${GOTESTSUM_VERSION}_${OS}_amd64.tar.gz | tar -zOxf - gotestsum > ./bin/gotestsum-${GOTESTSUM_VERSION} && chmod +x ./bin/gotestsum-${GOTESTSUM_VERSION}

TEST_PKGS ?= ./...
TEST_REPORT_NAME ?= results.xml
.PHONY: test
test: TEST_REPORT ?= main
test: TEST_FORMAT ?= short
test: SHELL = /bin/bash
test: bin/gotestsum ## Run tests
	@mkdir -p ${BUILD_DIR}/test_results/${TEST_REPORT}
	bin/gotestsum --no-summary=skipped --junitfile ${BUILD_DIR}/test_results/${TEST_REPORT}/${TEST_REPORT_NAME} --format ${TEST_FORMAT} -- $(filter-out -v,${GOARGS}) $(if ${TEST_PKGS},${TEST_PKGS},./...)

.PHONY: test-all
test-all: ## Run all tests
	@${MAKE} GOARGS="${GOARGS} -run .\*" TEST_REPORT=all test

.PHONY: test-integration
test-integration: ## Run integration tests
	@${MAKE} GOARGS="${GOARGS} -run ^TestIntegration\$$\$$" TEST_REPORT=integration test

.PHONY: test-functional
test-functional: ## Run functional tests
	@${MAKE} GOARGS="${GOARGS} -run ^TestFunctional\$$\$$" TEST_REPORT=functional test

bin/golangci-lint: bin/golangci-lint-${GOLANGCI_VERSION}
	@ln -sf golangci-lint-${GOLANGCI_VERSION} bin/golangci-lint
bin/golangci-lint-${GOLANGCI_VERSION}:
	@mkdir -p bin
	curl -sfL https://install.goreleaser.com/github.com/golangci/golangci-lint.sh | BINARY=golangci-lint bash -s -- v${GOLANGCI_VERSION}
	@mv bin/golangci-lint $@

.PHONY: lint
lint: bin/golangci-lint ## Run linter
	bin/golangci-lint run

bin/mga: bin/mga-${MGA_VERSION}
	@ln -sf mga-${MGA_VERSION} bin/mga
bin/mga-${MGA_VERSION}:
	@mkdir -p bin
	curl -sfL https://git.io/mgatool | bash -s v${MGA_VERSION}
	@mv bin/mga $@

.PHONY: generate
generate: bin/mga ## Generate code
	go generate -x ./...

.PHONY: validate-openapi
validate-openapi: ## Validate the OpenAPI descriptor
	for api in `ls ${OPENAPI_DESCRIPTOR_DIR}`; do \
	docker run --rm -v ${PWD}:/local openapitools/openapi-generator-cli:v${OPENAPI_GENERATOR_VERSION} validate --recommend -i /local/${OPENAPI_DESCRIPTOR_DIR}/$$api/swagger.yaml; \
	done

.PHONY: openapi
openapi: ## Generate client and server stubs from the OpenAPI definition
	rm -rf .gen/${OPENAPI_DESCRIPTOR_DIR}
	for api in `ls ${OPENAPI_DESCRIPTOR_DIR}`; do \
	docker run --rm -v ${PWD}:/local openapitools/openapi-generator-cli:v${OPENAPI_GENERATOR_VERSION} generate \
	--additional-properties packageName=api \
	--additional-properties withGoCodegenComment=true \
	-i /local/${OPENAPI_DESCRIPTOR_DIR}/$$api/swagger.yaml \
	-g go-server \
	-o /local/.gen/${OPENAPI_DESCRIPTOR_DIR}/$$api; \
	done

bin/protoc-gen-go:
	@mkdir -p bin
	go build -o bin/protoc-gen-go github.com/golang/protobuf/protoc-gen-go

bin/prototool: bin/prototool-${PROTOTOOL_VERSION}
	@ln -sf prototool-${PROTOTOOL_VERSION} bin/prototool
bin/prototool-${PROTOTOOL_VERSION}:
	@mkdir -p bin
	curl -L https://github.com/uber/prototool/releases/download/v${PROTOTOOL_VERSION}/prototool-${OS}-x86_64 > ./bin/prototool-${PROTOTOOL_VERSION} && chmod +x ./bin/prototool-${PROTOTOOL_VERSION}

.PHONY: validate-proto
validate-proto: bin/prototool bin/protoc-gen-go ## Validate protobuf definition
	bin/prototool $(if ${VERBOSE},--debug ,)compile
	bin/prototool $(if ${VERBOSE},--debug ,)lint
	bin/prototool $(if ${VERBOSE},--debug ,)break check

.PHONY: proto
proto: bin/prototool bin/protoc-gen-go ## Generate client and server stubs from the protobuf definition
	bin/prototool $(if ${VERBOSE},--debug ,)all

bin/gqlgen:
	@mkdir -p bin
	go build -o bin/gqlgen github.com/99designs/gqlgen

.PHONY: graphql
graphql: bin/gqlgen ## Generate GraphQL code
	bin/gqlgen

release-%: TAG_PREFIX = v
release-%:
ifneq (${DRY}, 1)
	@sed -e "s/^## \[Unreleased\]$$/## [Unreleased]\\"$$'\n'"\\"$$'\n'"\\"$$'\n'"## [$*] - $$(date +%Y-%m-%d)/g; s|^\[Unreleased\]: \(.*\/compare\/\)\(.*\)...HEAD$$|[Unreleased]: \1${TAG_PREFIX}$*...HEAD\\"$$'\n'"[$*]: \1\2...${TAG_PREFIX}$*|g" CHANGELOG.md > CHANGELOG.md.new
	@mv CHANGELOG.md.new CHANGELOG.md

ifeq (${TAG}, 1)
	git add CHANGELOG.md
	git commit -m 'Prepare release $*'
	git tag -m 'Release $*' ${TAG_PREFIX}$*
ifeq (${PUSH}, 1)
	git push; git push origin ${TAG_PREFIX}$*
endif
endif
endif

	@echo "Version updated to $*!"
ifneq (${PUSH}, 1)
	@echo
	@echo "Review the changes made by this script then execute the following:"
ifneq (${TAG}, 1)
	@echo
	@echo "git add CHANGELOG.md && git commit -m 'Prepare release $*' && git tag -m 'Release $*' ${TAG_PREFIX}$*"
	@echo
	@echo "Finally, push the changes:"
endif
	@echo
	@echo "git push; git push origin ${TAG_PREFIX}$*"
endif

.PHONY: patch
patch: ## Release a new patch version
	@${MAKE} release-$(shell (git describe --abbrev=0 --tags 2> /dev/null || echo "0.0.0") | sed 's/^v//' | awk -F'[ .]' '{print $$1"."$$2"."$$3+1}')

.PHONY: minor
minor: ## Release a new minor version
	@${MAKE} release-$(shell (git describe --abbrev=0 --tags 2> /dev/null || echo "0.0.0") | sed 's/^v//' | awk -F'[ .]' '{print $$1"."$$2+1".0"}')

.PHONY: major
major: ## Release a new major version
	@${MAKE} release-$(shell (git describe --abbrev=0 --tags 2> /dev/null || echo "0.0.0") | sed 's/^v//' | awk -F'[ .]' '{print $$1+1".0.0"}')

.PHONY: list
list: ## List all make targets
	@${MAKE} -pRrn : -f $(MAKEFILE_LIST) 2>/dev/null | awk -v RS= -F: '/^# File/,/^# Finished Make data base/ {if ($$1 !~ "^[#.]") {print $$1}}' | egrep -v -e '^[^[:alnum:]]' -e '^$@$$' | sort

.PHONY: help
.DEFAULT_GOAL := help
help:
	@grep -h -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

# Variable outputting/exporting rules
var-%: ; @echo $($*)
varexport-%: ; @echo $*=$($*)
