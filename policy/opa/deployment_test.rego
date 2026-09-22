# Policy tests. `opa test policy/opa -v` runs them with no cluster.
#
# Testing policy is not optional theatre: a policy with a typo in a field path
# silently allows everything, and the failure mode is invisible until an audit.
# A test that asserts a bad object IS denied is what proves the rule fires.
package mlops.admission_test

import data.mlops.admission
import rego.v1

good_deployment := {"review": {"object": {
	"kind": "Deployment",
	"metadata": {"namespace": "models", "annotations": {}},
	"spec": {"template": {"spec": {
		"securityContext": {"runAsNonRoot": true},
		"containers": [{
			"name": "api",
			"image": "wahabmlopsacr.azurecr.io/dataset-api:v1.2.0",
			"resources": {"limits": {"memory": "256Mi"}},
		}],
	}}},
}}}

test_good_deployment_allowed if {
	count(admission.deny) == 0 with input as good_deployment
}

test_foreign_registry_denied if {
	bad := json.patch(good_deployment, [{
		"op": "replace",
		"path": "/review/object/spec/template/spec/containers/0/image",
		"value": "docker.io/library/nginx:1.25",
	}])
	count(admission.deny) > 0 with input as bad
}

test_latest_tag_denied if {
	bad := json.patch(good_deployment, [{
		"op": "replace",
		"path": "/review/object/spec/template/spec/containers/0/image",
		"value": "wahabmlopsacr.azurecr.io/dataset-api:latest",
	}])
	count(admission.deny) > 0 with input as bad
}

test_missing_memory_limit_denied if {
	bad := json.patch(good_deployment, [{
		"op": "replace",
		"path": "/review/object/spec/template/spec/containers/0/resources",
		"value": {},
	}])
	count(admission.deny) > 0 with input as bad
}

test_root_denied if {
	bad := json.patch(good_deployment, [{
		"op": "replace",
		"path": "/review/object/spec/template/spec/securityContext",
		"value": {},
	}])
	count(admission.deny) > 0 with input as bad
}

test_prod_isvc_without_provenance_denied if {
	bad := {"review": {"object": {
		"kind": "InferenceService",
		"metadata": {"namespace": "models-prod", "annotations": {"mlops.io/model-card": "x"}},
		"spec": {"template": {"spec": {"containers": []}}},
	}}}
	count(admission.deny) > 0 with input as bad
}
