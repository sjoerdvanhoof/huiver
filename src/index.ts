import { serve } from "bun";
import { resumeInterruptedJobs } from "./server/convert";
import { IDLE_TIMEOUT_SECONDS, MAX_UPLOAD_BYTES, apiRoutes } from "./server/routes";
import index from "./index.html";

resumeInterruptedJobs();

const server = serve({
  maxRequestBodySize: MAX_UPLOAD_BYTES,
  idleTimeout: IDLE_TIMEOUT_SECONDS,

  routes: {
    ...apiRoutes,
    // Everything else falls through to the React app.
    "/*": index,
  },

  error(error) {
    console.error(error);
    return Response.json({ error: error.message }, { status: 500 });
  },

  development: process.env.NODE_ENV !== "production" && { hmr: true, console: true },
});

console.log(`🎧 huiver running at ${server.url}`);
