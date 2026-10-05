import os

from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.core.management.base import BaseCommand

class Command(BaseCommand):
    help = "Make sure a dashboard account exists when sign-in is required."

    def handle(self, *args, **options):
        if not settings.DASHBOARD_REQUIRE_LOGIN:
            return

        user_model = get_user_model()
        if user_model.objects.exists():
            return

        username = os.environ.get("DASHBOARD_USER", "").strip()
        password = os.environ.get("DASHBOARD_PASSWORD", "")
        if username and password:
            user_model.objects.create_superuser(username=username, password=password)
            self.stdout.write(f"Created dashboard account '{username}'.")
            return

        self.stdout.write("Sign-in is required and no account exists yet. Create one now.")
        call_command("createsuperuser")
