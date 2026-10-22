from app.models import UserProfile

def get_user_profile(uid: int) -> dict:
    row = UserProfile.query.filter_by(uid=uid).first()
    return {"uid": row.uid, "nick_name": row.nick_name}
