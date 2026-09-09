import type { LLMRequest } from "./LLMRequest.js";
import type { LLMResponse } from "./LLMResponse.js";

export interface LLMProvider {
  readonly name: string;
  generate(request: LLMRequest): Promise<LLMResponse>;
}
