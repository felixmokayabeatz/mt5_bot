from functools import wraps

from django.conf import settings
from django.contrib.auth.views import LoginView, redirect_to_login
from django.core.cache import cache
from django.http import HttpResponse, JsonResponse

def dashboard_access(view):
    @wraps(view)
    def wrapper(request, *args, **kwargs):
        if settings.DASHBOARD_REQUIRE_LOGIN and not request.user.is_authenticated:
            if request.path.startswith("/api/"):
                return JsonResponse({"error": "authentication required"}, status=401)
            return redirect_to_login(request.get_full_path())
        return view(request, *args, **kwargs)

    return wrapper

def failure_key(request):
    return "dashboard-login-failures:" + request.META.get("REMOTE_ADDR", "unknown")

class ThrottledLoginView(LoginView):
    template_name = "control/login.html"
    redirect_authenticated_user = True

    def dispatch(self, request, *args, **kwargs):
        if request.method == "POST":
            failures = cache.get(failure_key(request), 0)
            if failures >= settings.LOGIN_MAX_FAILURES:
                return HttpResponse(
                    "Too many failed sign-in attempts. Try again in a few minutes.",
                    status=429,
                    content_type="text/plain",
                )
        return super().dispatch(request, *args, **kwargs)

    def form_invalid(self, form):
        key = failure_key(self.request)
        cache.add(key, 0, settings.LOGIN_FAILURE_WINDOW_SECONDS)
        try:
            cache.incr(key)
        except ValueError:
            cache.set(key, 1, settings.LOGIN_FAILURE_WINDOW_SECONDS)
        return super().form_invalid(form)

    def form_valid(self, form):
        cache.delete(failure_key(self.request))
        return super().form_valid(form)
