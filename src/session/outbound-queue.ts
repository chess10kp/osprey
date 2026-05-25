/** Outbound user messages waiting for the agent to become idle. */

export class OutboundMessageQueue {
  private _items: string[] = [];

  get length(): number {
    return this._items.length;
  }

  /** Shallow copy for UI display. */
  peek(): readonly string[] {
    return this._items;
  }

  enqueue(text: string): void {
    const trimmed = text.trim();
    if (!trimmed) return;
    this._items.push(trimmed);
  }

  dequeue(): string | undefined {
    return this._items.shift();
  }

  clear(): void {
    this._items = [];
  }
}
