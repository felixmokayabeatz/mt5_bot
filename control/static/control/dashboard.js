/*
 * Recovery Shield dashboard polling.
 *
 * This file is served as a static asset, so it must not contain Django
 * template tags. Runtime configuration (status API URL, default version
 * labels and poll interval) is read from data-* attributes on the script tag
 * that loads this file, see control/templates/control/dashboard.html.
 */
(function () {
  "use strict";

  const script =
    document.currentScript || document.getElementById("dashboard-script") || {};
  const dataset = script.dataset || {};
  const config = {
    statusUrl: dataset.statusUrl || "/api/status/",
    defaultAppVersion: dataset.defaultAppVersion || "v1.0.7",
    defaultEaVersion: dataset.defaultEaVersion || "v1.0.7_11",
    pollIntervalMs: Number.parseInt(dataset.pollIntervalMs, 10) || 750,
  };

  async function refreshStatus() {
    try {
      const response = await fetch(config.statusUrl, { cache: "no-store" });
      const payload = await response.json();
      const status = payload.status || {};
      const control = payload.control || {};
      const model = payload.model || {};
      const version = payload.version || {};
      const counts = payload.counts || {};

      const runtime = payload.runtime_state || {};
      const statusPill = document.querySelector(".status-pill");
      statusPill.textContent = runtime.badge_label || (control.enabled === "1" ? "Command On" : "Paused");
      statusPill.dataset.enabled = control.enabled || "0";
      statusPill.dataset.state = runtime.badge_state || (control.enabled === "1" ? "warning" : "paused");

      document.getElementById("ea-message").textContent = status.ea_message || "No EA status yet";
      document.getElementById("app-version").textContent =
        status.app_version || version.app_version || config.defaultAppVersion;
      document.getElementById("ea-version").textContent = status.ea_version || "Waiting for EA";
      document.getElementById("compiled-header-version").textContent =
        version.ea_version || config.defaultEaVersion;
      document.getElementById("live-ea-version").textContent = status.ea_version || "Waiting for EA";
      document.getElementById("compiled-version").textContent = version.ea_version || config.defaultEaVersion;
      const compiledVersion = version.ea_version || config.defaultEaVersion;
      const runningVersion = status.ea_version || "unknown / old EA";
      const versionAlert = document.getElementById("version-alert");
      const versionMismatch = runningVersion !== compiledVersion;
      versionAlert.hidden = !versionMismatch;
      document.getElementById("compiled-alert-version").textContent = compiledVersion;
      document.getElementById("running-alert-version").textContent = runningVersion;
      document.getElementById("symbol").textContent = status.symbol || "-";
      document.getElementById("spread").textContent = status.spread || "-";
      document.getElementById("max-spread-status").textContent =
        status.max_spread || control.max_spread || "-";
      updateSpreadGate(status.spread, status.max_spread || control.max_spread);
      document.getElementById("entry-trend").textContent = status.entry_trend_signal || "WAIT";
      document.getElementById("entry-trend-detail").textContent = status.entry_trend_reason || "-";
      document.getElementById("scalp-burst").textContent =
        `${status.scalp_closed_trades || "0"} / ${status.scalp_max_closed_trades || "10"}`;
      document.getElementById("loss-streak").textContent = status.consecutive_losses || "0";
      document.getElementById("scalp-risk").textContent = status.scalp_risk_reason || "Ready.";
      document.getElementById("turns").textContent = status.turns || "0";
      document.getElementById("profit").textContent = status.total_profit || "0.00";
      document.getElementById("peak-profit").textContent = status.cycle_peak_profit || "0.00";
      document.getElementById("profit-lock").textContent =
        `${status.profit_lock_trigger || "0.00"} / -${status.profit_lock_giveback || "0.00"}`;
      document.getElementById("ultra-open").textContent =
        status.ultra_open_mode === "1" ? "Ultra open" : "Strict";
      document.getElementById("quick-target").textContent = status.quick_target_usd || "0.50";
      document.getElementById("max-loss").textContent = status.max_loss_usd || "0";
      document.getElementById("allow-recovery").textContent = status.allow_recovery === "1" ? "On" : "Off";
      document.getElementById("tp-sl-points").textContent =
        `${status.resolved_take_profit_points || status.take_profit_points || "-"} / ` +
        `${status.resolved_stop_loss_points || status.stop_loss_points || "-"}`;
      document.getElementById("account-currency").textContent =
        status.money_scale && status.money_scale !== "1.00"
          ? `${status.account_currency || "-"} (cent x${Number.parseFloat(status.money_scale)})`
          : (status.account_currency || "-");
      document.getElementById("atr-points").textContent = status.atr_points || "-";
      document.getElementById("max-lot").textContent = status.max_lot || "0.05";
      document.getElementById("max-same-side").textContent = status.max_same_side || "2";
      document.getElementById("same-side-distance").textContent = status.min_same_side_distance || "300";
      document.getElementById("model-score").textContent = status.model_score || "0.0000";
      document.getElementById("model-enabled").textContent =
        status.model_enabled === "1" ? "Active" : "Recording";
      document.getElementById("updated").textContent = status.updated_at || "-";
      document.getElementById("api-generated-at").textContent = payload.generated_at || "-";
      document.getElementById("trained-state").textContent =
        model.enabled === "1" ? "Enabled" : "Recording only";
      document.getElementById("trained-rows").textContent = model.trained_rows || "0";
      document.getElementById("win-loss").textContent =
        `${model.wins || "0"} / ${model.losses || "0"}`;
      document.getElementById("model-threshold").textContent = model.threshold || "0.55";
      document.getElementById("threshold-source").textContent = model.threshold_source || "default";
      document.getElementById("training-selected").textContent = model.training_selected || "0";
      document.getElementById("training-f1").textContent = model.training_f1 || "0.0000";
      document.getElementById("training-profit").textContent = model.training_total_profit || "0.00";
      document.getElementById("validation-rows").textContent = model.validation_rows || "0";
      document.getElementById("validation-selected").textContent = model.validation_selected || "0";
      document.getElementById("validation-f1").textContent = model.validation_f1 || "0.0000";
      document.getElementById("validation-profit").textContent = model.validation_total_profit || "0.00";
      document.getElementById("model-reason").textContent = model.reason || "No model file yet.";
      document.getElementById("event-rows").textContent = counts.events || "0";
      document.getElementById("cycle-rows").textContent = counts.cycles || "0";
    } catch (error) {
      document.getElementById("ea-message").textContent = "Dashboard cannot read status yet.";
    }
  }

  function updateSpreadGate(spreadValue, maxSpreadValue) {
    const spreadGate = document.getElementById("spread-gate");
    const spread = Number.parseFloat(spreadValue);
    const maxSpread = Number.parseFloat(maxSpreadValue);

    if (!Number.isFinite(spread) || !Number.isFinite(maxSpread)) {
      spreadGate.textContent = "-";
      spreadGate.dataset.state = "unknown";
      return;
    }

    if (spread > maxSpread) {
      spreadGate.textContent = `Blocked: ${spread} > ${maxSpread}`;
      spreadGate.dataset.state = "blocked";
    } else {
      spreadGate.textContent = `Open: ${spread} <= ${maxSpread}`;
      spreadGate.dataset.state = "open";
    }
  }

  // Expose the helpers so the polling loop stays testable from the console.
  window.RecoveryShield = { config, refreshStatus, updateSpreadGate };

  refreshStatus();
  setInterval(refreshStatus, config.pollIntervalMs);
})();
