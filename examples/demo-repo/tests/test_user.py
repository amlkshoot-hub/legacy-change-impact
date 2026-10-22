from app.services.user_service import get_user_profile

def test_profile():
    assert get_user_profile(1)["nick_name"] == "x"
