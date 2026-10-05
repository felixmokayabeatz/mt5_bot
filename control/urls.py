from django.contrib.auth.views import LogoutView
from django.urls import path

from . import views
from .auth import ThrottledLoginView

urlpatterns = [
    path("", views.dashboard, name="dashboard"),
    path("api/status/", views.status_api, name="status_api"),
    path("login/", ThrottledLoginView.as_view(), name="login"),
    path("logout/", LogoutView.as_view(), name="logout"),
]
