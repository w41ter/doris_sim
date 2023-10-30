# Doris Sim Env

A script to deploy doris env for testing.

## Example

**ONLY SUPPORT linux**

1. config env

```
cp config.template config.sh

# update configurations in config.sh, according the comments.
vim config.sh
```

> For backup/restore regression test, you should specified the variables with `STORE_` prefix.

2. deploy new cluster & start

```
bash bootstrap.sh deploy
bash bootstrap.sh start
```

3. run sql

```
# automatic
bash bootstrap.sh mysql <xxx.sql

# or manually
bash bootstrap.sql mysql
```

4. run regression test

```
bash bootstrap.sh run -- --run <suite-name>
```

5. stop and clean evn

```
bash bootstrap.sh stop
bash bootstrap.sh clean
```

Run `bash bootstrap.sh` for more details.


