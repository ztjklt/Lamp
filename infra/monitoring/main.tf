terraform {
  required_providers {
    google = { source = "hashicorp/google", version = "~> 7.0" }
  }
}

variable "project_id" { type = string }
variable "notification_channels" { type = list(string); default = [] }

provider "google" { project = var.project_id }

resource "google_logging_metric" "model_errors" {
  name   = "lamp/model_errors"
  filter = "resource.type=\"cloud_run_revision\" AND (jsonPayload.errorCode=\"LLM_ERROR\" OR jsonPayload.errorCode=\"MODEL_TIMEOUT\" OR jsonPayload.errorCode=\"MODEL_INVALID_OUTPUT\")"
  metric_descriptor { metric_kind = "DELTA"; value_type = "INT64"; unit = "1" }
}

resource "google_logging_metric" "planner_no_solution" {
  name   = "lamp/planner_no_solution"
  filter = "resource.type=\"cloud_run_revision\" AND jsonPayload.status=\"no_feasible_plan\""
  metric_descriptor { metric_kind = "DELTA"; value_type = "INT64"; unit = "1" }
}

resource "google_logging_metric" "state_conflicts" {
  name   = "lamp/state_conflicts"
  filter = "resource.type=\"cloud_run_revision\" AND (jsonPayload.errorCode=\"CONFLICT_ERROR\" OR jsonPayload.errorCode=\"STALE_STATE\")"
  metric_descriptor { metric_kind = "DELTA"; value_type = "INT64"; unit = "1" }
}

resource "google_logging_metric" "input_tokens" {
  name            = "lamp/input_tokens"
  filter          = "resource.type=\"cloud_run_revision\" AND jsonPayload.inputTokens>0"
  value_extractor = "EXTRACT(jsonPayload.inputTokens)"
  metric_descriptor { metric_kind = "DELTA"; value_type = "DOUBLE"; unit = "1" }
}

resource "google_monitoring_alert_policy" "server_errors" {
  display_name = "Lamp Agent Core 5xx spike"
  combiner     = "OR"
  notification_channels = var.notification_channels
  conditions {
    display_name = "Cloud Run 5xx rate"
    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND metric.type=\"run.googleapis.com/request_count\" AND metric.label.response_code_class=\"5xx\""
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "300s"
      aggregations { alignment_period = "60s"; per_series_aligner = "ALIGN_RATE" }
    }
  }
}

resource "google_monitoring_alert_policy" "model_errors" {
  display_name = "Lamp model error rate"
  combiner     = "OR"
  notification_channels = var.notification_channels
  conditions {
    display_name = "Model failures"
    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND metric.type=\"logging.googleapis.com/user/lamp/model_errors\""
      comparison      = "COMPARISON_GT"
      threshold_value = 3
      duration        = "300s"
      aggregations { alignment_period = "60s"; per_series_aligner = "ALIGN_RATE" }
    }
  }
}

resource "google_monitoring_alert_policy" "latency" {
  display_name = "Lamp Agent Core p95 latency"
  combiner     = "OR"
  notification_channels = var.notification_channels
  conditions {
    display_name = "p95 above language budget"
    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND metric.type=\"run.googleapis.com/request_latencies\""
      comparison      = "COMPARISON_GT"
      threshold_value = 8000
      duration        = "300s"
      aggregations { alignment_period = "60s"; per_series_aligner = "ALIGN_PERCENTILE_95" }
    }
  }
}

resource "google_monitoring_dashboard" "lamp" {
  dashboard_json = jsonencode({
    displayName = "Lamp Harness Production"
    mosaicLayout = {
      columns = 12
      tiles = [
        { width = 6, height = 4, widget = { title = "Requests", xyChart = { dataSets = [{ timeSeriesQuery = { timeSeriesFilter = { filter = "metric.type=\"run.googleapis.com/request_count\" resource.type=\"cloud_run_revision\"", aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE" } } } }] } } },
        { width = 6, height = 4, widget = { title = "p95 latency", xyChart = { dataSets = [{ timeSeriesQuery = { timeSeriesFilter = { filter = "metric.type=\"run.googleapis.com/request_latencies\" resource.type=\"cloud_run_revision\"", aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_PERCENTILE_95" } } } }] } } },
        { width = 4, height = 4, widget = { title = "Model errors", scorecard = { timeSeriesQuery = { timeSeriesFilter = { filter = "metric.type=\"logging.googleapis.com/user/lamp/model_errors\" resource.type=\"cloud_run_revision\"" } } } } },
        { width = 4, height = 4, widget = { title = "Planner no-solution", scorecard = { timeSeriesQuery = { timeSeriesFilter = { filter = "metric.type=\"logging.googleapis.com/user/lamp/planner_no_solution\" resource.type=\"cloud_run_revision\"" } } } } },
        { width = 4, height = 4, widget = { title = "409 / 410 conflicts", scorecard = { timeSeriesQuery = { timeSeriesFilter = { filter = "metric.type=\"logging.googleapis.com/user/lamp/state_conflicts\" resource.type=\"cloud_run_revision\"" } } } } },
        { width = 6, height = 4, widget = { title = "Input tokens", xyChart = { dataSets = [{ timeSeriesQuery = { timeSeriesFilter = { filter = "metric.type=\"logging.googleapis.com/user/lamp/input_tokens\" resource.type=\"cloud_run_revision\"", aggregation = { alignmentPeriod = "3600s", perSeriesAligner = "ALIGN_SUM" } } } }] } } },
      ]
    }
  })
}
