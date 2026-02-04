.PHONY: build run stop clean logs test help

IMAGE_NAME := percona/valkey
IMAGE_TAG := 9.0.2-hardened

help:
	@echo "Valkey Hardened Docker Image"
	@echo ""
	@echo "Available targets:"
	@echo "  build    - Build hardened Docker image"
	@echo "  run      - Start Valkey container with docker-compose"
	@echo "  stop     - Stop Valkey container"
	@echo "  logs     - Show container logs"
	@echo "  test     - Test the built image"
	@echo "  clean    - Remove containers, volumes, and images"
	@echo "  all      - Build and test"

build:
	@echo "Building hardened Valkey image..."
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) -f Dockerfile.hardened .

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

test:
	@echo "Testing Valkey image..."
	@echo "1. Checking valkey-server version..."
	@docker run --rm $(IMAGE_NAME):$(IMAGE_TAG) valkey-server --version
	@echo "2. Checking valkey-cli version..."
	@docker run --rm $(IMAGE_NAME):$(IMAGE_TAG) valkey-cli --version
	@echo "3. Verifying non-root user..."
	@docker run --rm $(IMAGE_NAME):$(IMAGE_TAG) id
	@echo ""
	@echo "✅ All tests passed!"

clean:
	@echo "Cleaning up..."
	docker-compose down -v
	docker rmi $(IMAGE_NAME):$(IMAGE_TAG) || true
	@echo "✅ Cleanup complete!"

all: build test
	@echo ""
	@echo "✅ Build and test complete!"
