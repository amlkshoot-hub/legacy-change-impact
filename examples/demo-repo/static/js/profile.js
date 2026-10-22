const url = "/api/v1/users/profile?uid=" + uid;
fetch(url).then(r => r.json());
