ROUTES = {}

def add_route(path, handler_name):
    ROUTES[path] = handler_name

add_route("/api/v1/users/profile", "get_user_profile")
