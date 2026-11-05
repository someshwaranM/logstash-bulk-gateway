# Logos

These four SVG files are the unmodified logo files from the `@elastic/eui` npm package, version 123.3.0 (`dist/svgs/logo_*.svg`):

- `elastic.svg`
- `elasticsearch.svg`
- `kibana.svg`
- `logstash.svg`

Elastic, Elasticsearch, Kibana and Logstash are trademarks of Elasticsearch B.V. The EUI license covers EUI's source code and doesn't grant any right to use the trademarks. Check the Elastic brand guidelines (brand.elastic.co) before using these logos outside of Elastic content.

The Elasticsearch, Kibana and Logstash files use a CSS class named `euiIcon__fillNegative` for their dark segment. EUI supplies that color from its own CSS. If you open a file on its own, that segment has no fill, so add `.euiIcon__fillNegative { fill: #343741; }` to see it. The diagrams in this folder already do that.
