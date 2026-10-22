from app.services.user_service import get_user_profile
from celery import shared_task

@shared_task(name="sync_user_profile")
def sync(uid):
    return get_user_profile(uid)
