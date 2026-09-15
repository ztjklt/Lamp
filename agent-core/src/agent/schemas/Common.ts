import { z } from "zod";

export const IdentifierSchema = z.string().trim().min(1).max(200);
export const UUIDSchema = z.uuid();
export const TimestampSchema = z.iso.datetime({ offset: true });
export const ConfidenceSchema = z.number().min(0).max(1);
export const JsonObjectSchema = z.record(z.string(), z.unknown());

export type JsonObject = z.infer<typeof JsonObjectSchema>;
