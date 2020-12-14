#!/bin/bash

function show_help() {
    cat << EOF
Usage: ${0##*/} -b branch -o oauth_token [-t tag] [-r -u dockerhub_user -p dockerhub_password]
    -b      [dev|release]
    -o      oauth token for github
    -t      tag images with the given string
    -r      push images to a registry
    -u      username for authentication on dockerhub
    -p      password for authentication on dockerhub
EOF
}

#we want to be able to interupt the build, see: http://veithen.github.io/2014/11/16/sigterm-propagation.html
function run() {
    trap 'kill -TERM $PID' TERM INT
    $@ &
    PID=$!
    wait $PID
    trap - TERM INT
    wait $PID
    return $?
}


while getopts "o:t:b:rp:u:h" opt; do
    case $opt in
        o) token=$OPTARG
            ;;
        t) tag=$OPTARG
            ;;
        b) branch=$OPTARG
            ;;
        r) push=1
            ;;
        p) password=$OPTARG
            ;;
        u) user=$OPTARG
            ;;
        h|\?)
            show_help
            exit 1
            ;;
    esac
done

if [[ -z $token ]] ||  [[ -z $branch ]];
then
     echo "Missing argument."
     show_help
     exit 1
fi

if [[ $branch == "dev" ]]; then
    workflow="build_navitia_packages_for_dev_multi_distribution.yml"
    archive="navitia-debian8-packages.zip"
    inside_archive="navitia_debian8_packages.zip"
elif [[ $branch == "release" ]]; then
    workflow="build_navitia_packages_for_release.yml"
    archive="navitia-debian-packages.zip"
    inside_archive="navitia_debian_packages.zip"
else 
    echo """branch must be "dev" or "release" """
    echo "***${branch}***"
    show_help
    exit 1
fi

if [[ $push -eq 1 ]]; then
    if [ -z $user ];
    then 
        echo """Cannot push to docker registry without a "-u user." """
        show_help
        exit 1
    fi
    if [ -z $password ]; then 
    echo """Cannot push to docker registry without a "-p password." """
        show_help
        exit 1
    fi  
fi

# clone navitia source code
rm -rf ./navitia/
git clone https://x-token-auth:${token}@github.com/CanalTP/navitia.git --branch $branch ./navitia/

# let's dowload the package built on gihub actions
# for that we need the submodule core_team_ci_tools
git submodule update --init

# we setup the right python environnement to use core_team_ci_tools
pip install virtualenv -U
virtualenv -py python3 ci_tools
. ci_tools/bin/activate
pip install -r core_team_ci_tools/github_artifacts/requirements.txt

# let's download the navitia packages
rm -f $archive
python core_team_ci_tools/github_artifacts/github_artifacts.py -o CanalTP -r navitia -t $token -w $workflow -a $archive --output-dir .

# let's unzip what we received
rm -f ./$inside_archive
unzip ${archive}

# let's unzip (again) to obtain the pacakges
rm -f navitia*.deb
unzip ${inside_archive} -d .

# let's dowload mimirsbrunn package
python core_team_ci_tools/github_artifacts/github_artifacts.py -o CanalTP -r mimirsbrunn -t $token -w build_package.yml -a "archive.zip" --output-dir .

rm -f mimirsbrunn*.deb
unzip archive.zip -d .

deactivate

components='jormungandr kraken tyr-beat tyr-worker tyr-web instances-configurator'

pushd navitia
version=$(git describe)
echo "building version $version"
popd

for component in $components; do
    echo "*********  Building $component ***************"
    run docker build --no-cache -t navitia/$component:$version -f  Dockerfile-${component} .
    
    # tag image if a -t tag was given
    if [ -n $tag ]; then
        run docker tag navitia/$component:$version navitia/$component:$tag
    fi
done




# push image to docker registry if required with -r
if [[ $push -eq 1 ]]; then
    docker login -u $user -p $password
    for component in $components; do
        docker push navitia/$component:$version
        # also push tagged image if -t tag was given
        if [ -n $tag ]; then
            docker push navitia/$component:tag
        fi
    done
    docker logout
fi


# clean up
# we remove the ./navitia/ dir
rm -rf ./navitia/
# the dowloaded archive for navitia package
rm -f ./$archive
# what was inside the archive
rm -f ./$inside_archive

# and all dowloaded packages
rm -rf navitia_debian8_packages/

# the archive from mimirsbrunn package
rm -f archive.zip
# and what was inside the package
rm -f mimirsbrunn*.deb