# ea-webapp

This package provides adapters that allow cPanel’s Web Apps API
(and thus any consumers-MCP, UI, CLI, etc) to manage web apps
implemented in whatever language and framework we want to support.

## Extending

If a 3rd party wishes to provide additional adapters they can do so
by publishing a package like `ea-webapp-example` that installs
their adapters to `/var/cpanel/web-app-toolkit/vendor/example/`,
where `example` is the vendor’s name/slug.

## Anatomy of a an adapter

… WiP …
