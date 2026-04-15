.PHONY: build build-hardened build-rpm run stop clean logs test test-hardened test-rpm help all

IMAGE_NAME := perconalab/valkey
VALKEY_VERSION := 9.0.3
REPO_CHANNEL ?= experimental

TAG_HARDENED := $(VALKEY_VERSION)-hardened
TAG_RPM := $(VALKEY_VERSION)

help:
	@echo "Valkey Docker Images"
	@echo ""
	@echo "Available targets:"
	@echo "  build          - Build both images (hardened + RPM)"
	@echo "  build-hardened - Build hardened DHI image (Dockerfile.hardened)"
	@echo "  build-rpm      - Build RPM/UBI9 image (Dockerfile)"
	@echo "  test           - Test both images"
	@echo "  test-hardened  - Test hardened image"
	@echo "  test-rpm       - Test RPM image"
	@echo "  run            - Start Valkey container with docker-compose"
	@echo "  stop           - Stop Valkey container"
	@echo "  logs           - Show container logs"
	@echo "  clean          - Remove containers, volumes, and images"
	@echo "  all            - Build and test both images"
	@echo ""
	@echo "Variables:"
	@echo "  REPO_CHANNEL   - Percona repo channel (default: experimental)"
	@echo "                   Usage: make build REPO_CHANNEL=release"

build: build-hardened build-rpm

build-hardened:
	@echo "Building hardened Valkey image (DHI)..."
	docker build --build-arg REPO_CHANNEL=$(REPO_CHANNEL) -t $(IMAGE_NAME):$(TAG_HARDENED) -f Dockerfile.hardened .

build-rpm:
	@echo "Building RPM Valkey image (UBI9)..."
	docker build --build-arg REPO_CHANNEL=$(REPO_CHANNEL) -t $(IMAGE_NAME):$(TAG_RPM) -f Dockerfile .

test: test-hardened test-rpm

test-hardened:
	VALKEY_VERSION=$(VALKEY_VERSION) ./test-image.sh $(IMAGE_NAME):$(TAG_HARDENED) hardened

test-rpm:
	VALKEY_VERSION=$(VALKEY_VERSION) ./test-image.sh $(IMAGE_NAME):$(TAG_RPM) rpm

run:
	@echo "Starting Valkey..."
	docker-compose up -d
	@echo "Waiting for container to be healthy..."
	@sleep 5
	@docker-compose ps

stop:
	@echo "Stopping Valkey..."
	docker-compose down

logs:
	docker-compose logs -f valkey

clean:
	@echo "Cleaning up..."
	docker-compose down -v
	docker rmi $(IMAGE_NAME):$(TAG_HARDENED) || true
	docker rmi $(IMAGE_NAME):$(TAG_RPM) || true
	@echo "Cleanup complete!"

all: build test
	@echo "All builds and tests complete!"
