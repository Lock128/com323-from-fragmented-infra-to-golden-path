// function-observability — a Crossplane composition function, in Go.
//
// WHY GO (the demo point): the FinOps extension used patch-and-transform — fine
// for "map one field to one field". Observability is different: the result is the
// CROSS-PRODUCT of two dimensions (tier × language) turned into LISTS of alerts
// and dashboards, with conditional rules. Expressing "build the union of a
// tier-driven alert set and a language-specific dashboard set" is natural in Go
// (loops, maps, conditionals) and genuinely awkward in YAML patches. So when the
// logic outgrows patches, you drop into a real Go function.
//
// The function reads spec.tier and spec.language off the Service composite and
// emits one typed ObservabilitySetup record describing the chosen alerts,
// dashboards, routing, and scrape settings. (Records, not a live Prometheus — the
// Go logic is the star; the record is "what the platform decided".)
package main

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/crossplane/function-sdk-go/errors"
	"github.com/crossplane/function-sdk-go/logging"
	fnv1 "github.com/crossplane/function-sdk-go/proto/v1"
	"github.com/crossplane/function-sdk-go/request"
	"github.com/crossplane/function-sdk-go/resource"
	"github.com/crossplane/function-sdk-go/resource/composed"
	"github.com/crossplane/function-sdk-go/response"
)

// Function implements the composition function gRPC server.
type Function struct {
	fnv1.UnimplementedFunctionRunnerServiceServer
	log logging.Logger
}

// ── the observability policy, expressed as Go ───────────────────────────────

// alertsForTier returns the alert rules enabled for a criticality tier.
// experimental → none · standard → latency+errors · critical → + SLO burn & saturation.
func alertsForTier(tier string) []string {
	switch tier {
	case "critical":
		return []string{
			"HighErrorRate",      // 5xx ratio
			"HighLatencyP99",     // p99 latency SLO
			"SLOBurnRateFast",    // multi-window burn-rate
			"SaturationCPU",      // resource saturation
			"SaturationMemory",
			"SyntheticProbeDown", // blackbox/synthetic check
		}
	case "standard":
		return []string{"HighErrorRate", "HighLatencyP99"}
	default: // experimental
		return []string{}
	}
}

// pagingForTier returns how alerts are routed for a tier.
func pagingForTier(tier string) (route, severity string) {
	switch tier {
	case "critical":
		return "pagerduty-24x7", "page"
	case "standard":
		return "slack-business-hours", "ticket"
	default:
		return "none", "silent"
	}
}

// dashboardsForLanguage returns the runtime-specific dashboard panels. THIS is the
// clumsy-in-YAML part: each language has its own signal set.
func dashboardsForLanguage(language string) []string {
	common := []string{"RED-overview", "HTTP-traffic", "Resource-usage"}
	switch language {
	case "go":
		return append(common, "Go-goroutines", "Go-GC-pause", "Go-memstats")
	case "node":
		return append(common, "Node-eventloop-lag", "Node-heap", "Node-GC")
	case "python":
		return append(common, "Python-worker-saturation", "Python-request-queue", "Python-GC")
	case "php":
		return append(common, "PHP-FPM-pool", "PHP-opcache", "PHP-request-duration")
	default:
		return common
	}
}

// scrapeForLanguage returns the metrics endpoint/exporter hint per runtime.
func scrapeForLanguage(language string) (path, exporter string) {
	switch language {
	case "go":
		return "/metrics", "prometheus-client-go"
	case "node":
		return "/metrics", "prom-client"
	case "python":
		return "/metrics", "prometheus-client-python"
	case "php":
		return "/metrics", "php-fpm-exporter"
	default:
		return "/metrics", "generic"
	}
}

// RunFunction is called by Crossplane with the observed/desired state.
func (f *Function) RunFunction(_ context.Context, req *fnv1.RunFunctionRequest) (*fnv1.RunFunctionResponse, error) {
	f.log.Info("Running function-observability", "tag", req.GetMeta().GetTag())
	rsp := response.To(req, response.DefaultTTL)

	// Read the composite (the Service XR) to get tier + language + name/team.
	oxr, err := request.GetObservedCompositeResource(req)
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot get observed composite resource"))
		return rsp, nil
	}

	svc, _ := oxr.Resource.GetString("spec.name")
	team, _ := oxr.Resource.GetString("spec.team")
	tier, err := oxr.Resource.GetString("spec.tier")
	if err != nil || tier == "" {
		tier = "standard"
	}
	language, err := oxr.Resource.GetString("spec.language")
	if err != nil || language == "" {
		language = "go"
	}
	if svc == "" {
		// Nothing to compose for an XR without a name yet.
		return rsp, nil
	}

	// Compute the observability setup in Go.
	alerts := alertsForTier(tier)
	route, severity := pagingForTier(tier)
	dashboards := dashboardsForLanguage(language)
	scrapePath, exporter := scrapeForLanguage(language)
	sort.Strings(alerts)
	sort.Strings(dashboards)

	f.log.Info("composing observability", "service", svc, "tier", tier, "language", language,
		"alerts", len(alerts), "dashboards", len(dashboards))

	// Build the desired composed resource: a provider-kubernetes Object that
	// wraps our typed ObservabilitySetup CRD, so it lands in the cluster. We set
	// the unstructured content directly (version-robust across SDK releases).
	name := "obs-" + svc
	manifest := map[string]any{
		"apiVersion": "platform.lockhead.cloud/v1alpha1",
		"kind":       "ObservabilitySetup",
		"metadata": map[string]any{
			"name":      name,
			"namespace": "sre-system",
			"labels": map[string]any{
				"lockhead.cloud/registration": "observability",
				"lockhead.cloud/managed-by":   "crossplane",
				"lockhead.cloud/service":      svc,
			},
		},
		"spec": map[string]any{
			"service":         svc,
			"team":            team,
			"tier":            tier,
			"language":        language,
			"alerts":          toAnySlice(alerts),
			"dashboards":      toAnySlice(dashboards),
			"alertRoute":      route,
			"alertSeverity":   severity,
			"scrapePath":      scrapePath,
			"metricsExporter": exporter,
			"summary": fmt.Sprintf("%s/%s: %d alerts (%s), %d dashboards",
				tier, language, len(alerts), strings.Join(alerts, ","), len(dashboards)),
		},
	}
	cd := composed.New()
	cd.Unstructured.Object = map[string]any{
		"apiVersion": "kubernetes.crossplane.io/v1alpha2",
		"kind":       "Object",
		"metadata":   map[string]any{"name": name},
		"spec": map[string]any{
			"providerConfigRef": map[string]any{"name": "in-cluster"},
			"forProvider":       map[string]any{"manifest": manifest},
		},
	}

	desired, err := request.GetDesiredComposedResources(req)
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot get desired composed resources"))
		return rsp, nil
	}
	// Mark the record Ready explicitly. An ObservabilitySetup is a declarative
	// record ("what the platform decided"), not a runtime resource with its own
	// readiness lifecycle. If we leave Ready Unspecified, Crossplane keeps the
	// whole XR (and the developer's Claim) stuck at Ready=False on
	// "Unready resources: observability-setup" — so we assert readiness here.
	desired[resource.Name("observability-setup")] = &resource.DesiredComposed{
		Resource: cd,
		Ready:    resource.ReadyTrue,
	}

	if err := response.SetDesiredComposedResources(rsp, desired); err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot set desired composed resources"))
		return rsp, nil
	}

	response.Normalf(rsp, "observability: %s/%s → %d alerts, %d dashboards", tier, language, len(alerts), len(dashboards))
	return rsp, nil
}

func toAnySlice(ss []string) []any {
	out := make([]any, len(ss))
	for i, s := range ss {
		out[i] = s
	}
	return out
}
