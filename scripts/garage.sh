#!/bin/sh

exec kubectl exec -it -n garage statefulset/garage -c garage -- /garage "$@"
