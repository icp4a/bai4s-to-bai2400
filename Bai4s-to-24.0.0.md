
# Migration guide from BAI for Server to Kubernetes v24.0.0

This guide is associated to a bash script `helper.sh` that defines functions to ease the migration
from BAI4S to K8S.

## Limitations and assumptions

The Kubernetes version of BAI, given the nature of the platform, is basically different
from the one server version. The data are still compatible, though, which
allows a path to upgrade from BAI4S to 24.0.0 with some sensible restrictions.

- The migration takes care of stateless information only. All active summaries are lost.
- The event processing must be shut down during the migration.
- The migration process described here works for the original deployement of BAI4S. Custom
configurations may lead to unexpected results.
- Dashboard owner names and permission team names are not changed.

The BAI4S and K8S environments are very different. It is very unlikely a user can access both production environments
from the same terminal session, given all the expected access constraints. This is why the process
we describe here is split in independent steps that can be performed in different places.

## Description of the migration process

All data are stored in BAI4S Elasticsearch. We are going to create a snapshot of them, to copy the snapshot to K8S Opensearch, load
the snapshot to Opensearch, and inject the indices into local indices.

All the operations can be performed at once in the same session, but obviously some operational constraints
(typically: security access) may require to split the process on different environments. The description below represents "the happy path" and
can not take into account all the possible situations, so the reader should adapt the procedure to fit local constraints.

If a step can not be performed, it is suggested to edit the function in `helper.sh` so it fits the situation.

## Migration steps

### Prepare the migration

- Open a bash session on the machine where BAI4S is installed. Be sure to have `jq` and `oc` installed.
- Shut down the emiters and wait for BAI to become idle.
- Run the commands below:

```
# set BAI4S_INSTALL_DIR to the BAI4S installation root dir.
BAI4S_INSTALL_DIR=/opt/ibm/BAI4S
source helper.sh
```

- `helper.sh` does nothing, it only defines functions in the current shell session. In case you have to move to another
shell, be sure to source again the file before performing any other action.

###  Operations on BAI4S

- Run `initBAI4Senv` to set Elasticsearch credentials.
- Run `patchBAI4S` once for all. This command enable snapshots in BAI4S by patching ElasticSearch configuration file, and restart ElasticSearch.
Wait a bit ElasticSearch is up and running.
- Run `makeSnapshot` to create a snapshot. If the snapshot must be refreshed, use the command `deleteSnapshot` to clear the snapshot.
- At this point BAI4S is not needed any more, it should be stopped.

### Copy the snapshot

The snapshot is stored on the filesystem as a tree of files. The next step will copy it to the cluster, which supposes
to have access of the current filesystem and the target cluster in the same session. Otherwise, copy the snapshot directory to a better
place (see `copySnapshotToOS` function)

- Log in the cluster, using `oc login ...`.
- run `getOScredentials` to initialize credentials variables.
- run `copySnapshotToOS ` to upload the snapshot. Do it once.

### Restore data

At this point, the snapshot containing BAI4S indices is inside OpenSearch, ready to load.

Note: The communication to Opensearch goes through cluster proxys that may cut the connection if the request does not complete within 30 seconds. Messages
like **Gateway issue** or **Response: 506** typically indicates a proxy time out rather than a real issue. It means the operation will probably complete correctly,
but later. The commands in this section can take several minutes to complete, according to the volume of data to process.

- run `restoreSnapshotOnOS` to load indices. However the indice names and mappings has changed. The next command will inject the old
indices into new indices that have been created by default. 
- run `transformIndices` to update the indices with BAI4S content. This command also delete the old indices. In case of trouble, redo the cycle
`restoreSnapshotOnOS` and `transformIndices`.

The migration is over. You can redirect the emitters to BAI 24.0.0 and start them.

###  Optional post-processing

Authentication may be different between BAI4S and K8S. In case the dahsboard owner names have changed, edit the documents in index `icp4ba-bai-store-dasboards`.

The permissions are stored in index `icp4ba-bai-store-permissions`. Edit the documents inside in case there is also a name mapping to perform.

The template dashboards for 24.0.0 are saved in index `orig-icp4ba-bai-store-dashboards`, just in case they are needed.
