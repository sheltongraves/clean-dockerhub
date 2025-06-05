#!/bin/bash
set -e

if [ -z $DOCKERHUB_USERNAME ]; then
    echo "Missing DOCKERHUB_USERNAME environment var"
    exit 1
fi

if [ -z $DOCKERHUB_PASSWORD ]; then
    echo "Missing DOCKERHUB_PASSWORD environment var"
    exit 1
fi

if [ -z $DOCKERHUB_NAMESPACE ]; then
    echo "Missing DOCKERHUB_NAMESPACE environment var"
    exit 1
fi

DOCKERHUB_API="https://hub.docker.com/v2"
REGISTRY_API="https://registry-1.docker.io/v2"
REPO_PREFIXES="^(webapp-)" #if you want to add new ones, syntax will be "^(webapp-|api-|microservice-)" etc.

refresh_token() {
  TOKEN=$(curl -s -X POST "$DOCKERHUB_API/users/login/" \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"$DOCKERHUB_USERNAME\", \"password\": \"$DOCKERHUB_PASSWORD\"}" | jq -r .token)

  echo "Token refreshed"
}

delete_digest() {
  local namespace=$1
  local repository=$2
  local digest=$3
  local repo="$namespace/$repository"

  local response_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$REGISTRY_API/$repo/manifests/$digest" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json")

  if [ "$response_code" -eq 202 ]; then
    echo "Manifest [$digest] deleted!"
  else
    echo "Error when deleting manifest [$digest] : returned HTTP code was [$response_code]"

    if [ "$response_code" -eq 401 ]; then
      refresh_token
    fi
  fi
}

clean_repo_manifests() {

  local namespace=$1
  local repository=$2

  local list_repo_manifests_url="$DOCKERHUB_API/namespaces/$namespace/repositories/$repository/manifests?last_evaluated_key="
  local last_evaluated_key=""

  while [ -n "${list_repo_manifests_url}${last_evaluated_key}" ]; do

    if [[ "$last_evaluated_key" == "null" ]]; then
      return
    fi

    echo "Calling URL [${list_repo_manifests_url}${last_evaluated_key}]"

    local response=$(curl -s -X GET "${list_repo_manifests_url}${last_evaluated_key}" -H "Authorization: JWT $TOKEN")
    if [[ "$response" == *"httperror 404"* ]]; then
      exit
    fi

    local manifests=$(echo "$response" | jq -c '.manifests[]')

    for manifest in $manifests; do

      local manifest_digest=$(echo "$manifest" | jq -r .manifest_digest)
      local manifest_tags=$(echo "$manifest" | jq -r .tags[] | tr '\n' ' ' | xargs)
      local manifest_last_pulled=$(echo "$manifest" | jq -r .last_pulled)

      if echo "$manifest_tags" | grep -Eq "latest|backup"; then

        echo "Manifest [$manifest_digest] found, last pull was [$manifest_last_pulled] : to keep (protected tag word found in [$manifest_tags])"
        continue
      fi

      if [[ "$manifest_last_pulled" != "null" ]] && [[ "$manifest_last_pulled" != "0001-01-01T00:00:00Z" ]]; then

        local manifest_last_pulled_date=$(date -d "$manifest_last_pulled" +%s)
        local one_month_ago_date=$(date -d "1 month ago" +%s)

        if [ "$manifest_last_pulled_date" -lt "$one_month_ago_date" ]; then

            echo "Manifest [$manifest_digest] found, last pull was [$manifest_last_pulled] : to delete (last pull > 1 month ago)"
            delete_digest $namespace $repository "$manifest_digest"
          else

            echo "Manifest [$manifest_digest] found, last pull was [$manifest_last_pulled] : to keep (last pull < 1 month ago)"
          fi
      else
        echo "Manifest [$manifest_digest] found, last pull was [$manifest_last_pulled] : to delete (never pulled)"
        delete_digest $namespace $repository "$manifest_digest"
      fi
    done

    last_evaluated_key=$(echo "$response" | jq -r .last_evaluated_key)
    sleep 5
  done
}

list_repos() {

  local namespace=$1
  local list_repos_url="$DOCKERHUB_API/namespaces/$namespace/repositories?page_size=25"

  while [ -n "$list_repos_url" ]; do

    if [[ "$list_repos_url" == "null" ]]; then
      return
    fi

    refresh_token
    echo "Calling URL [$list_repos_url]"

    local response=$(curl -s -X GET "$list_repos_url" -H "Authorization: JWT $TOKEN")
    local repos=$(echo "$response" | jq -c '.results[]')

    echo "$repos" | while read -r repo; do
      local repo_name=$(echo "$repo" | jq -r .name)

      if [[ "$repo_name" =~ $REPO_PREFIXES ]]; then
        echo "Repo [$repo_name] found"
        clean_repo_manifests "$namespace" "$repo_name"
      else
        echo "Repo [$repo_name] found but ignored"
      fi
    done

    list_repos_url=$(echo "$response" | jq -r .next)
    sleep 5
  done
}

list_repos "$DOCKERHUB_NAMESPACE"
