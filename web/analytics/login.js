// Hands the ID token from Sign in with Google to auth.php, which verifies it.
// Kept out of the page so the Content-Security-Policy needs no inline script.
window.wrenSignedIn = function (response) {
  var error = document.getElementById("error");
  error.textContent = "";
  var body = new URLSearchParams({
    action: "login",
    credential: response.credential,
    csrf: document.querySelector('meta[name="csrf"]').content,
  });
  fetch("auth.php", { method: "POST", body: body, credentials: "same-origin" })
    .then(function (r) {
      return r.json().then(function (j) { return { ok: r.ok, j: j }; });
    })
    .then(function (res) {
      if (res.ok) location.reload();
      else error.textContent = res.j.error || "Sign-in failed.";
    })
    .catch(function () { error.textContent = "Sign-in failed. Check the connection and try again."; });
};
