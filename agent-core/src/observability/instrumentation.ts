import { getNodeAutoInstrumentations } from "@opentelemetry/auto-instrumentations-node";
import { NodeSDK } from "@opentelemetry/sdk-node";

const enabled = process.env["OTEL_SDK_DISABLED"] !== "true" &&
  process.env["OTEL_EXPORTER_OTLP_ENDPOINT"] !== undefined;

const sdk = enabled ? new NodeSDK({
  instrumentations: [getNodeAutoInstrumentations({
    "@opentelemetry/instrumentation-fs": { enabled: false },
  })],
}) : null;

sdk?.start();

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.once(signal, () => { void sdk?.shutdown(); });
}
