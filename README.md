# MT5 Recovery Shield

Small Django dashboard and training helper for a MetaTrader 5 recovery bot demo setup.

## What is included

- A browser dashboard for start, pause, and close-all commands
- File-based status polling from the MT5 common files directory
- A simple training script that builds a lightweight trade filter from closed cycles

## Quick start

1. Install the Python requirements.
2. Start the dashboard with `python manage.py runserver`.
3. Point MT5 shared files at the same common files directory used by the app.

## MT5 files

Set `MT5_COMMON_FILES_DIR` when you want the dashboard and trainer to read from a custom shared folder instead of the default MetaTrader common files path.

Set `MODEL_THRESHOLD` if you want the trainer to write a different decision cutoff into the generated model file.
