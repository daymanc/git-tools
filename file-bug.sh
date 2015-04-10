#!/bin/bash

set -e
set -x
set -o pipefail

if [ -z "$FILESERVER" -o -z "$RELEASE_VERSION" -o -z "$GITHUB_OWNER" -o -z "$TEST_BUILD_NUMBER" \
     -o -z "$PIVOTAL_TOKEN" -o -z "$PIVOTAL_PROJECT_ID" -o -z "$PIVOTAL_OWNER_ID" ]
then
    echo "Required variable not set" >&2
    exit 1
fi

if [ "$GITHUB_OWNER" != "piston" ]; then
    exit 0
fi

if ! [ "$TEST_GITHUB_OWNER" = "piston" -o -z "$TEST_GITHUB_OWNER" ]; then
    exit 0
fi

LABEL_ID="5803519"
JOB_LINK="https://albino.piston.cc/job/Functional_Tests/$TEST_BUILD_NUMBER/console"
FILESERVER_LINKS=("http://$FILESERVER/builds/$GITHUB_OWNER/$GITHUB_BRANCH/debug/functional-test-$RELEASE_VERSION-$TEST_BUILD_NUMBER.log"
                  "http://$FILESERVER/builds/$GITHUB_OWNER/$GITHUB_BRANCH/debug/functional-test-$RELEASE_VERSION-$TEST_BUILD_NUMBER.log.gz")

DESCRIPTION="$JOB_LINK\n"

for LINK in "${FILESERVER_LINKS[@]}"
do
    # If we get anything that's not a 200 or a 404 there's something really wrong, file a bug on
    # the whole system
    case "$(curl -o /dev/null --silent  --write-out '%{http_code}\n' $LINK)" in
        *"200"*)                                          
            DESCRIPTION="$DESCRIPTION\n$LINK"
            ;;                                                             
        *"404"*)                                      
            DESCRIPTION="$DESCRIPTION\n[404/NotFound] => $LINK"
            ;;                                                             
        *)                                             
            DESCRIPTION="Error: The log links didn't provide a return code we could parse!\n\Build system is currently unstable in it's log reporting."
            ;;                                                             
    esac
done

read -r -d '' json <<-EOF || true
{"story_type": "bug",
 "name": "Test Failure: $RELEASE_VERSION [$TEST_BUILD_NUMBER] [Automatically filed by Jenkins]",
 "owner_ids": [$PIVOTAL_OWNER_ID],
 "label_ids": [$LABEL_ID],
 "description": "$DESCRIPTION"
}
EOF

echo "Filing Pivotal bug for $RELEASE_VERSION"
curl --retry 5 --retry-delay 5 -H "X-TrackerToken: $PIVOTAL_TOKEN" -X POST -H "Content-type: application/json" \
     -d "$json" https://www.pivotaltracker.com/services/v5/projects/$PIVOTAL_PROJECT_ID/stories

 #"description": "https://albino.piston.cc/job/Functional_Tests/$TEST_BUILD_NUMBER/console\nhttp://$FILESERVER/builds/$GITHUB_OWNER/$GITHUB_BRANCH/debug/functional-test-$RELEASE_VERSION-$TEST_BUILD_NUMBER.log\nhttp://$FILESERVER/builds/$GITHUB_OWNER/$GITHUB_BRANCH/debug/functional-test-$RELEASE_VERSION-$TEST_BUILD_NUMBER.log.gz"
