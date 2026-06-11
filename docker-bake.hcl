// docker-bake.hcl — single source of truth for all Docker image builds.
//
// Targets:
//   dev     — local single-arch build, loads into Docker daemon
//   ci      — multi-arch validation build, no push
//   release — multi-arch build, pushes to registry

variable "REGISTRY" {
  default = "ghcr.io"
}

variable "IMAGE_NAME" {
  default = "donaldgifford/repo-guardian-operator"
}

variable "VERSION" {
  default = "dev"
}

variable "COMMIT_SHA" {
  default = ""
}

variable "BUILD_DATE" {
  default = ""
}

function "tags" {
  params = [name, version]
  result = version == "dev" ? [
    "${REGISTRY}/${name}:dev",
    ] : [
    "${REGISTRY}/${name}:${version}",
    "${REGISTRY}/${name}:latest",
  ]
}

// Base target with shared configuration.
target "_common" {
  context = "."
  labels = {
    "org.opencontainers.image.source"   = "https://github.com/donaldgifford/wiz-operator"
    "org.opencontainers.image.revision" = "${COMMIT_SHA}"
    "org.opencontainers.image.created"  = "${BUILD_DATE}"
    "org.opencontainers.image.version"  = "${VERSION}"
  }
}

// Local development build — single-arch, loads into Docker daemon.
target "dev" {
  inherits = ["_common"]
  tags     = tags("dev")
  output   = ["type=docker"]
}

// CI validation build — multi-arch, no push.
target "ci" {
  inherits   = ["_common"]
  dockerfile = "Dockerfile"
  tags       = tags(VERSION)
  platforms  = ["linux/amd64", "linux/arm64"]
  output     = ["type=cacheonly"]
  cache-from = ["type=gha"]
  cache-to   = ["type=gha,mode=max"]
}

// Populated by docker/metadata-action in CI with computed tags and labels.
// Default tags are used for local `make docker-push`; CI overrides via bake file merge.
target "docker-metadata-action" {
  tags = tags(VERSION)
}

// Release build — multi-arch, pushes to registry.
// Tags are inherited from docker-metadata-action (overridden by metadata-action in CI).
target "release" {
  inherits   = ["_common", "docker-metadata-action"]
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64", "linux/arm64"]
  output     = ["type=registry"]
  cache-from = ["type=gha"]
  cache-to   = ["type=gha,mode=max"]
}
