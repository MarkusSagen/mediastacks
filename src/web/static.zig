//! Static assets embedded at compile time. Updating any of the three
//! files under src/web/assets/ requires a `zig build` to refresh.

pub const index_html = @embedFile("assets/index.html");
pub const app_js = @embedFile("assets/app.js");
pub const styles_css = @embedFile("assets/styles.css");
pub const favicon_svg = @embedFile("assets/favicon.svg");

pub const review_html = @embedFile("assets/review.html");
pub const review_js = @embedFile("assets/review.js");
pub const review_css = @embedFile("assets/review.css");
