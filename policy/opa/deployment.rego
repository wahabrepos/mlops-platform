# Admission policy for model deployments.
#
# HOW THIS IS ENFORCED: OPA Gatekeeper runs as a Kubernetes admission webhook.
# The API server calls it before persisting any object, and a `deny` here means
# `kubectl apply` fails with this message. The policy is not advice a pipeline
# can skip — it is a wall in front of the cluster, and it applies equally to a
# CI robot and to you at 2am with a kubectl command.
#
# Test it without a cluster:
#   opa test policy/opa -v
package mlops.admission

import rego.v1

# --- 1. Images must come from our registry ---------------------------------
# An image from Docker Hub in a production namespace has not been through our
# build, scan, or signing pipeline. Pinning the registry is the cheapest
# meaningful supply-chain control there is.
deny contains msg if {
	input.review.object.kind in {"Deployment", "InferenceService"}
	some container in all_containers
	not startswith(container.image, "wahabmlopsacr.azurecr.io/")
	msg := sprintf("image %q is not from the approved registry wahabmlopsacr.azurecr.io", [container.image])
}

# --- 2. No mutable tags ----------------------------------------------------
# `:latest` means the running image can change without any Kubernetes object
# changing, which makes "what is deployed?" unanswerable and rollback
# meaningless. Digests are immutable; semver tags are at least traceable.
deny contains msg if {
	some container in all_containers
	endswith(container.image, ":latest")
	msg := sprintf("image %q uses the mutable tag :latest; use a digest or a version tag", [container.image])
}

# --- 3. Production models must declare their provenance --------------------
# This is the Project 6 governance gate expressed as code. A model serving
# production traffic must be traceable to the MLflow run that produced it, the
# dataset version it learned from, and the model card that documents it.
# Without these three, an audit cannot be answered.
required_annotations := {
	"mlops.io/mlflow-run-id",
	"mlops.io/dataset-version",
	"mlops.io/model-card",
}

deny contains msg if {
	input.review.object.kind == "InferenceService"
	input.review.object.metadata.namespace == "models-prod"
	some required in required_annotations
	not input.review.object.metadata.annotations[required]
	msg := sprintf("production InferenceService is missing required annotation %q", [required])
}

# --- 4. Resource limits are mandatory --------------------------------------
# A container with no memory limit can consume the node and evict its
# neighbours. This is the noisy-neighbour problem, and one required field
# prevents it.
deny contains msg if {
	some container in all_containers
	not container.resources.limits.memory
	msg := sprintf("container %q has no memory limit", [container.name])
}

# --- 5. Nothing runs as root ----------------------------------------------
deny contains msg if {
	input.review.object.kind == "Deployment"
	input.review.object.spec.template.spec.securityContext.runAsNonRoot != true
	msg := "pod securityContext must set runAsNonRoot: true"
}

# Helper: flatten containers out of whichever shape the object has.
all_containers contains container if {
	some container in input.review.object.spec.template.spec.containers
}

all_containers contains container if {
	some container in input.review.object.spec.template.spec.initContainers
}
