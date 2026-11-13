# Local shortcuts. Each target mirrors a CI job.
CHART := charts/twelve-factor-app
VALUES := $(wildcard $(CHART)/ci/*.yaml) examples/values-production.yaml examples/kind/values.yaml

.PHONY: lint unittest template kubeconform e2e all

lint:            ## helm lint every values file (also validates values.schema.json)
	helm lint --strict $(CHART)
	@for f in $(VALUES); do echo "--- $$f"; helm lint --strict $(CHART) -f $$f || exit 1; done

unittest:        ## helm-unittest (helm plugin install https://github.com/helm-unittest/helm-unittest)
	helm unittest $(CHART)

template:        ## print the rendered manifests with production values
	helm template orders $(CHART) -n shop -f examples/values-production.yaml

kubeconform:     ## validate rendered YAML against Kubernetes schemas
	@for f in $(VALUES); do helm template orders $(CHART) -f $$f | kubeconform -strict -summary \
	  -schema-location default \
	  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' || exit 1; done

e2e:             ## full test on kind (kind create cluster --name twelve-factor first)
	./scripts/e2e-kind.sh

all: lint unittest kubeconform
