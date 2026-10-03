(function () {
  "use strict";

  const script =
    document.currentScript || document.getElementById("dashboard-script") || {};
  const dataset = script.dataset || {};
  const config = {
    statusUrl: dataset.statusUrl || "/api/status/",
    defaultAppVersion: dataset.defaultAppVersion || "-",
    defaultEaVersion: dataset.defaultEaVersion || "-",
    pollIntervalMs: Number.parseInt(dataset.pollIntervalMs, 10) || 750,
  };

  let refreshInFlight = false;

  function setText(id, value) {
    const element = document.getElementById(id);
    if (element) {
      element.textContent = value;
    }
  }

  function flagLabel(value, onLabel, offLabel) {
    if (value === "1") {
      return onLabel;
    }
    return value ? offLabel : "-";
  }

  async function refreshStatus() {
    if (refreshInFlight) {
      return;
    }

    refreshInFlight = true;
    try {
      const response = await fetch(config.statusUrl, { cache: "no-store" });
      if (!response.ok) {
        throw new Error(`status request failed: ${response.status}`);
      }

      const payload = await response.json();
      const status = payload.status || {};
      const control = payload.control || {};
      const model = payload.model || {};
      const version = payload.version || {};
      const counts = payload.counts || {};
      const runtime = payload.runtime_state || {};

      const statusPill = document.querySelector(".status-pill");
      if (statusPill) {
        statusPill.textContent =
          runtime.badge_label || (control.enabled === "1" ? "Command On" : "Paused");
        statusPill.dataset.enabled = control.enabled || "0";
        statusPill.dataset.state =
          runtime.badge_state || (control.enabled === "1" ? "warning" : "paused");
      }

      const compiledVersion = version.ea_version || config.defaultEaVersion;
      const runningVersion = status.ea_version || "unknown / old EA";
      const versionMismatch =
        runtime.version_mismatch !== undefined
          ? Boolean(runtime.version_mismatch)
          : runningVersion !== compiledVersion;
      const versionAlert = document.getElementById("version-alert");
      if (versionAlert) {
        versionAlert.hidden = !versionMismatch;
      }

      setText("ea-message", status.ea_message || "No EA status yet");
      setText("app-version", status.app_version || version.app_version || config.defaultAppVersion);
      setText("ea-version", status.ea_version || "Waiting for EA");
      setText("compiled-header-version", compiledVersion);
      setText("live-ea-version", status.ea_version || "Waiting for EA");
      setText("compiled-version", compiledVersion);
      setText("compiled-alert-version", compiledVersion);
      setText("running-alert-version", runningVersion);
      setText("symbol", status.symbol || "-");
      setText("spread", status.spread || "-");
      setText("max-spread-status", status.max_spread || control.max_spread || "-");
      updateSpreadGate(status.spread, status.max_spread || control.max_spread);
      setText("entry-trend", status.entry_trend_signal || "WAIT");
      setText("entry-trend-detail", status.entry_trend_reason || "-");
      setText(
        "scalp-burst",
        `${status.scalp_closed_trades || "0"} / ${status.scalp_max_closed_trades || "-"}`
      );
      setText("loss-streak", status.consecutive_losses || "0");
      setText("scalp-risk", status.scalp_risk_reason || "Ready.");
      setText("turns", status.turns || "0");
      setText("profit", status.total_profit || "0.00");
      setText("peak-profit", status.cycle_peak_profit || "0.00");
      setText(
        "profit-lock",
        `${status.profit_lock_trigger || "0.00"} / -${status.profit_lock_giveback || "0.00"}`
      );
      setText("ultra-open", flagLabel(status.ultra_open_mode, "Ultra open", "Strict"));
      setText("quick-target", status.quick_target_usd || "-");
      setText("requested-quick-target", status.requested_quick_target_usd || "-");
      setText("target-points", status.effective_target_points || "-");
      setText("max-loss", status.max_loss_usd || "-");
      setText("allow-recovery", flagLabel(status.allow_recovery, "On", "Off"));
      setText(
        "tp-sl-points",
        `${status.resolved_take_profit_points || status.take_profit_points || "-"} / ` +
          `${status.resolved_stop_loss_points || status.stop_loss_points || "-"}`
      );
      setText(
        "account-currency",
        status.money_scale && Number.parseFloat(status.money_scale) !== 1
          ? `${status.account_currency || "-"} (cent x${Number.parseFloat(status.money_scale)})`
          : status.account_currency || "-"
      );
      setText("atr-points", status.entry_atr_points || status.atr_points || "-");
      setText("max-lot", status.max_lot || "-");
      setText("max-same-side", status.max_same_side || "-");
      setText("same-side-distance", status.min_same_side_distance || "-");
      setText("model-score", status.model_score || "0.0000");
      setText("model-enabled", status.model_enabled === "1" ? "Active" : "Recording");
      setText("updated", status.updated_at || "-");
      setText("api-generated-at", payload.generated_at || "-");
      setText("trained-state", model.enabled === "1" ? "Enabled" : "Recording only");
      setText("trained-rows", model.trained_rows || "0");
      setText("win-loss", `${model.wins || "0"} / ${model.losses || "0"}`);
      setText("model-threshold", model.threshold || "0.55");
      setText("threshold-source", model.threshold_source || "default");
      setText("training-selected", model.training_selected || "0");
      setText("training-f1", model.training_f1 || "0.0000");
      setText("training-profit", model.training_total_profit || "0.00");
      setText("validation-rows", model.validation_rows || "0");
      setText("validation-selected", model.validation_selected || "0");
      setText("validation-f1", model.validation_f1 || "0.0000");
      setText("validation-profit", model.validation_total_profit || "0.00");
      setText("model-reason", model.reason || "No model file yet.");
      setText("event-rows", counts.events || "0");
      setText("cycle-rows", counts.cycles || "0");
    } catch (error) {
      setText("ea-message", "Dashboard cannot read status yet.");
    } finally {
      refreshInFlight = false;
    }
  }

  function updateSpreadGate(spreadValue, maxSpreadValue) {
    const spreadGate = document.getElementById("spread-gate");
    if (!spreadGate) {
      return;
    }

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

  window.RecoveryShield = { config, refreshStatus, updateSpreadGate };

  refreshStatus();
  setInterval(refreshStatus, config.pollIntervalMs);
})();
