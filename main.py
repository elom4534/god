import os
from fastapi import FastAPI

app = FastAPI(title="god - Alwaysdata", version="1.0")

@app.get("/")
def root():
    return {"status": "god online", "ip": os.getenv("IP", "0.0.0.0"), "port": os.getenv("PORT", "8100")}

@app.get("/health")
def health():
    return {"ok": True}

if __name__ == "__main__":
    import uvicorn
    host = os.getenv("IP", "0.0.0.0")
    port = int(os.getenv("PORT", "8100"))
    print(f"Starting main.py on {host}:{port}")
    uvicorn.run(app, host=host, port=port, log_level="info")
