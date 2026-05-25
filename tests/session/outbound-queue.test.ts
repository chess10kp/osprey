import { describe, expect, it } from "vitest";
import { OutboundMessageQueue } from "../../src/session/outbound-queue.js";

describe("OutboundMessageQueue", () => {
  it("enqueues and dequeues in order", () => {
    const q = new OutboundMessageQueue();
    q.enqueue("first");
    q.enqueue("second");
    expect(q.length).toBe(2);
    expect(q.dequeue()).toBe("first");
    expect(q.dequeue()).toBe("second");
    expect(q.length).toBe(0);
  });

  it("ignores empty strings", () => {
    const q = new OutboundMessageQueue();
    q.enqueue("   ");
    expect(q.length).toBe(0);
  });

  it("clear removes all pending items", () => {
    const q = new OutboundMessageQueue();
    q.enqueue("a");
    q.enqueue("b");
    q.clear();
    expect(q.length).toBe(0);
    expect(q.peek()).toEqual([]);
  });
});
