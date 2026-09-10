.DEFAULT_GOAL := help

IMAGE_NAME  ?= ghcr.io/jlaska/fwupd
IMAGE_TAG   ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
PLATFORM    ?= linux/amd64

.PHONY: help setup lint test build docker push run clean distclean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

setup: ## Install pre-commit hooks and dev dependencies
	pre-commit install
	uv sync

lint: ## Run all linters (pre-commit hooks)
	pre-commit run --all-files

test: ## Run Python tests
	uv run pytest tests/ -v

build: lint test ## Lint, test, then build Docker image
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .

docker: ## Build Docker image (skip lint/test)
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .

push: build ## Build and push Docker image
	docker push $(IMAGE_NAME):$(IMAGE_TAG)

run: docker ## Run container with help subcommand
	docker run --rm $(IMAGE_NAME):$(IMAGE_TAG) help

clean: ## Remove Python caches and build artifacts
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .pytest_cache -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .mypy_cache -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name '*.egg-info' -exec rm -rf {} + 2>/dev/null || true
	rm -rf dist/ build/

distclean: clean ## Remove everything including venv and Docker image
	rm -rf .venv
	-docker rmi $(IMAGE_NAME):$(IMAGE_TAG) 2>/dev/null
