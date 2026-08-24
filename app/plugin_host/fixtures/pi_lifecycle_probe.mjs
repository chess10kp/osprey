/**
 * Lifecycle-probe extension fixture.
 *
 * Listens under the cheap Pi lifecycle event names and echoes an
 * `<event>:<json>` marker string per delivery, so tests can assert the
 * arbitrary-name hook_fire pass-through reaches extension listeners over
 * the real wire (not just the fake host).
 */

export default function (pi) {
  const echo = (event) => async (data) =>
    `${event}:${JSON.stringify(data ?? {})}`;
  pi.on("user_bash", echo("user_bash"));
  pi.on("project_trust", echo("project_trust"));
  pi.on("message_start", echo("message_start"));
  pi.on("message_update", echo("message_update"));
  pi.on("session_before_switch", echo("session_before_switch"));
  pi.on("session_info_changed", echo("session_info_changed"));
}
