import type { DomainEvent } from "./DomainEvent.js";
import { DomainEventSchema, freezeDomainEvent } from "./DomainEvent.js";

export type EventType = DomainEvent["type"] | "*";
export type EventHandler = (event: Readonly<DomainEvent>) => Promise<void>;

export class EventBus {
  private readonly handlers = new Map<EventType, EventHandler[]>();
  private readonly publishedEventIds = new Set<string>();

  subscribe(type: EventType, handler: EventHandler): () => void {
    const handlers = this.handlers.get(type) ?? [];
    handlers.push(handler);
    this.handlers.set(type, handlers);
    return () => {
      const current = this.handlers.get(type) ?? [];
      this.handlers.set(type, current.filter((candidate) => candidate !== handler));
    };
  }

  async publish(rawEvent: unknown): Promise<boolean> {
    const event = freezeDomainEvent(DomainEventSchema.parse(rawEvent));
    if (this.publishedEventIds.has(event.eventId)) return false;
    this.publishedEventIds.add(event.eventId);
    const handlers = [...(this.handlers.get(event.type) ?? []), ...(this.handlers.get("*") ?? [])];
    try {
      for (const handler of handlers) await handler(event);
      return true;
    } catch (error) {
      this.publishedEventIds.delete(event.eventId);
      throw error;
    }
  }
}
