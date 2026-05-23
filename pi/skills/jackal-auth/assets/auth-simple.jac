# Simple Authentication Example (state-based, no routing)
cl import from '@jac/runtime' { jacSignup, jacLogin, jacLogout, jacIsLoggedIn }

to cl:

def:pub app -> JsxElement {
    has isLoggedIn: bool = False,
        currentPage: str = "login",
        username: str = "",
        password: str = "",
        error: str = "",
        loading: bool = False;

    # Check login status on mount
    can with entry {
        logged_in = jacIsLoggedIn();
        isLoggedIn = logged_in;
        if logged_in {
            currentPage = "dashboard";
        }
    }

    # Handle login
    async def handleLogin -> None {
        error = "";
        if not username.strip() or not password {
            error = "Please fill in all fields";
            return;
        }
        loading = True;
        success = await jacLogin(username, password);
        loading = False;
        if success {
            isLoggedIn = True;
            currentPage = "dashboard";
            username = "";
            password = "";
        } else {
            error = "Invalid credentials";
        }
    }

    # Handle signup
    async def handleSignup -> None {
        error = "";
        if not username.strip() or not password {
            error = "Please fill in all fields";
            return;
        }
        loading = True;
        result = await jacSignup(username, password);
        if result["success"] {
            # /user/register does not return a token, sign in to start a session
            logged_in = await jacLogin(username, password);
            loading = False;
            if logged_in {
                isLoggedIn = True;
                currentPage = "dashboard";
                username = "";
                password = "";
            } else {
                error = "Account created but login failed";
            }
        } else {
            loading = False;
            error = result["error"] if result["error"] else "Signup failed";
        }
    }

    # Handle logout
    def handleLogout {
        jacLogout();
        isLoggedIn = False;
        currentPage = "login";
        username = "";
        password = "";
        error = "";
    }

    # Logged in view - Dashboard
    if isLoggedIn {
        return
            <div
                style={{
                    "minHeight": "100vh",
                    "background": "#f5f5f5",
                    "fontFamily": "system-ui, sans-serif"
                }}
            >
                <nav
                    style={{
                        "padding": "12px 24px",
                        "background": "#3b82f6",
                        "color": "#ffffff",
                        "display": "flex",
                        "justifyContent": "space-between"
                    }}
                >
                    <div style={{"fontWeight": "600"}}>My App</div>
                    <button
                        onClick={handleLogout}
                        style={{
                            "background": "none",
                            "color": "#ffffff",
                            "border": "1px solid #ffffff",
                            "padding": "2px 10px",
                            "borderRadius": "4px",
                            "cursor": "pointer"
                        }}
                    >
                        Logout
                    </button>
                </nav>
                <div
                    style={{
                        "maxWidth": "600px",
                        "margin": "20px auto",
                        "padding": "20px",
                        "background": "#ffffff",
                        "borderRadius": "8px",
                        "boxShadow": "0 2px 4px rgba(0,0,0,0.1)"
                    }}
                >
                    <h1 style={{"marginBottom": "20px"}}>Welcome!</h1>
                    <p style={{"fontSize": "16px", "lineHeight": "1.6"}}>
                        You are logged in. This is a protected page.
                    </p>
                    <p style={{"fontSize": "14px", "color": "#666"}}>
                        Click the Logout button in the navigation to sign out.
                    </p>
                </div>
            </div>;
    }

    # Login/Signup view
    return
        <div
            style={{
                "minHeight": "100vh",
                "background": "#f5f5f5",
                "display": "flex",
                "alignItems": "center",
                "justifyContent": "center",
                "fontFamily": "system-ui, sans-serif"
            }}
        >
            <div
                style={{
                    "background": "#ffffff",
                    "padding": "30px",
                    "borderRadius": "8px",
                    "width": "280px",
                    "boxShadow": "0 2px 4px rgba(0,0,0,0.1)"
                }}
            >
                <h2 style={{"marginBottom": "20px", "textAlign": "center"}}>
                    {("Sign Up" if currentPage == "signup" else "Login")}
                </h2>

                {(
                    <div
                        style={{
                            "color": "#dc2626",
                            "fontSize": "14px",
                            "marginBottom": "10px",
                            "padding": "8px",
                            "background": "#fee2e2",
                            "borderRadius": "4px"
                        }}
                    >
                        {error}
                    </div>
                )
                    if error
                    else None}

                <input
                    type="text"
                    value={username}
                    onChange={lambda e: Any { username = e.target.value; }}
                    placeholder="Username"
                    style={{
                        "width": "100%",
                        "padding": "8px",
                        "marginBottom": "10px",
                        "border": "1px solid #ddd",
                        "borderRadius": "4px",
                        "boxSizing": "border-box"
                    }}
                />
                <input
                    type="password"
                    value={password}
                    onChange={lambda e: Any { password = e.target.value; }}
                    placeholder="Password"
                    style={{
                        "width": "100%",
                        "padding": "8px",
                        "marginBottom": "10px",
                        "border": "1px solid #ddd",
                        "borderRadius": "4px",
                        "boxSizing": "border-box"
                    }}
                />
                <button
                    disabled={loading}
                    onClick={lambda {
                        if currentPage == "signup" {
                            await handleSignup();
                        } else {
                            await handleLogin();
                        }
                    }}
                    style={{
                        "width": "100%",
                        "padding": "8px",
                        "background": (("#9ca3af" if loading else "#3b82f6")),
                        "color": "#ffffff",
                        "border": "none",
                        "borderRadius": "4px",
                        "cursor": (("not-allowed" if loading else "pointer")),
                        "fontWeight": "600"
                    }}
                >
                    {(
                        "Processing..." if loading else ("Sign Up" if currentPage == "signup" else "Login")
                    )}
                </button>
                <p
                    style={{
                        "textAlign": "center",
                        "marginTop": "12px",
                        "fontSize": "14px"
                    }}
                >
                    {(
                        ("Already have an account? " if currentPage == "signup" else "Need an account? ")
                    )}
                    <button
                        onClick={lambda {
                            currentPage = ("login" if currentPage == "signup" else "signup");
                            error = "";
                            username = "";
                            password = "";
                        }}
                        style={{
                            "background": "none",
                            "border": "none",
                            "color": "#3b82f6",
                            "cursor": "pointer",
                            "textDecoration": "underline",
                            "padding": "0"
                        }}
                    >
                        {("Login" if currentPage == "signup" else "Sign up")}
                    </button>
                </p>
            </div>
        </div>;
}
