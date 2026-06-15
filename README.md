# ea-web-app-hub

This package provides adaptors that allow cPanel’s Web App Hub API
(and thus any consumers-MCP, UI, CLI, etc) to manage web apps
implemented in whatever language and framework we wanr to support.

## Extending

If a 3rd party wishes to provide additional adaptors they can do so
by publishing a package like `ea-web-app-hub-example` that installs
their adaptors to `/var/cpanel/web-app-toolkit/vendor/example/`,
where `example` is the vendor’s name/slug.

## Anatomy of a an adaptor

… WiP …
