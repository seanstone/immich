"""Regenerates the fork's mergedAsset* queries in merged_asset.drift.

The fork pages the main timeline over narrow sort keys, seeks pages from a
cursor and picks overview covers; these queries share one page CTE and one
row shape, so they are generated rather than edited by hand.

Usage (from mobile/): python3 scripts/fork_merged_asset_queries.py lib/data/db/main/query/merged_asset.drift
then run build_runner. On a rebase, carry upstream's filters and columns into
the templates below first: the script replaces everything from the first
mergedAsset query up to mergedBucket.
"""
import sys

path = sys.argv[1]
src = open(path).read()
head, rest = src.split("mergedAsset", 1)
tail = rest[rest.index("mergedBucket("):]

def page_cte(remote_extra, local_extra, order, limit):
    return f"""WITH page AS (
	SELECT
		rae.id as remote_id,
		NULL as local_id,
		rae.group_date as page_group_date,
		rae.created_at as page_created_at,
		CAST(rae.created_at AS TEXT) as sort_created_at,
		rae.id as sort_id
	FROM
		remote_asset_entity rae
	LEFT JOIN
		stack_entity se ON rae.stack_id = se.id
	WHERE
		rae.deleted_at IS NULL
		AND rae.visibility = 0 -- timeline visibility
		AND rae.owner_id IN :user_ids
		AND rae.group_date IS NOT NULL
		AND (
			rae.stack_id IS NULL
			OR rae.id = se.primary_asset_id
		){remote_extra}

	UNION ALL

	SELECT
		NULL as remote_id,
		lae.id as local_id,
		lae.group_date as page_group_date,
		lae.created_at as page_created_at,
		CAST(lae.created_at AS TEXT) as sort_created_at,
		lae.id as sort_id
	FROM
		local_asset_entity lae
	WHERE NOT EXISTS (
		SELECT 1 FROM remote_asset_entity rae WHERE rae.checksum = lae.checksum AND rae.owner_id IN :user_ids
	)
	AND EXISTS (
		SELECT 1 FROM local_album_asset_entity laa
		INNER JOIN local_album_entity la on laa.album_id = la.id
		WHERE laa.asset_id = lae.id AND la.backup_selection = 0 -- selected
	)
	AND NOT EXISTS (
		SELECT 1 FROM local_album_asset_entity laa
		INNER JOIN local_album_entity la on laa.album_id = la.id
		WHERE laa.asset_id = lae.id AND la.backup_selection = 2 -- excluded
	)
	AND lae.group_date IS NOT NULL{local_extra}
	ORDER BY {order}
	{limit}
)"""

BODY = """SELECT
	rae.id as remote_id,
	(SELECT lae.id FROM local_asset_entity lae WHERE lae.checksum = rae.checksum LIMIT 1) as local_id,
	rae.name,
	rae."type",
	rae.created_at as created_at,
	rae.updated_at,
	rae.width,
	rae.height,
	rae.duration_ms,
	rae.is_favorite,
	rae.thumb_hash,
	rae.checksum,
	rae.owner_id,
	rae.live_photo_video_id,
	0 as orientation,
	rae.stack_id,
	NULL as i_cloud_id,
	NULL as latitude,
	NULL as longitude,
	NULL as adjustmentTime,
	rae.is_edited,
	0 as playback_style,
	rae.uploaded_at,
	rae.group_date,
	page.sort_created_at,
	page.sort_id
FROM
	page
INNER JOIN
	remote_asset_entity rae ON rae.id = page.remote_id

UNION ALL

SELECT
	NULL as remote_id,
	lae.id as local_id,
	lae.name,
	lae."type",
	lae.created_at as created_at,
	lae.updated_at,
	lae.width,
	lae.height,
	lae.duration_ms,
	lae.is_favorite,
	NULL as thumb_hash,
	lae.checksum,
	NULL as owner_id,
	NULL as live_photo_video_id,
	lae.orientation,
	NULL as stack_id,
	lae.i_cloud_id,
	lae.latitude,
	lae.longitude,
	lae.adjustment_time,
	0 as is_edited,
	lae.playback_style,
	NULL as uploaded_at,
	lae.group_date,
	page.sort_created_at,
	page.sort_id
FROM
	page
INNER JOIN
	local_asset_entity lae ON lae.id = page.local_id
ORDER BY group_date DESC, created_at DESC, sort_id DESC;
"""

DESC = "page_group_date DESC, page_created_at DESC, sort_id DESC"
ASC = "page_group_date ASC, page_created_at ASC, sort_id ASC"
CURSOR = "(:cursor_group_date, :cursor_created_at, :cursor_sort_id)"
CURSOR_ARGS = "(:cursor_group_date AS TEXT, :cursor_created_at AS TEXT, :cursor_sort_id AS TEXT)"

def seek(alias, op):
    return f"\n\t\tAND ({alias}.group_date, {alias}.created_at, {alias}.id) {op} {CURSOR}"

def lseek(op):
    return f"\n\tAND (lae.group_date, lae.created_at, lae.id) {op} {CURSOR}"

RANGE_ARGS = "(:range_start AS TEXT, :range_end AS TEXT)"

def in_range(alias):
    return f"\n\t\tAND {alias}.group_date >= :range_start AND {alias}.group_date < :range_end"

def lin_range():
    return "\n\tAND lae.group_date >= :range_start AND lae.group_date < :range_end"

queries = [
    f"""mergedAsset AS MergedAssetRow:
-- Page on the narrow sort keys first, then fetch full rows for that page only.
-- A UNION ALL with OFFSET otherwise materialises every skipped row in full,
-- making deep pages cost linear in the whole library.
{page_cte('', '', DESC, 'LIMIT :count OFFSET :offset')}
{BODY}""",
    f"""mergedAssetOlderThan{CURSOR_ARGS} AS MergedAssetRow:
-- Keyset page: the :count assets that sort directly after the cursor. The
-- cursor holds the raw stored sort keys, compared as text so it matches the
-- index exactly; seeks instead of counting past newer assets.
{page_cte(seek('rae', '<'), lseek('<'), DESC, 'LIMIT :count')}
{BODY}""",
    f"""mergedAssetNewerThan{CURSOR_ARGS} AS MergedAssetRow:
-- Keyset page: the :count assets that sort directly before the cursor,
-- returned in timeline order.
{page_cte(seek('rae', '>'), lseek('>'), ASC, 'LIMIT :count')}
{BODY}""",
    f"""mergedAssetCover{RANGE_ARGS} AS MergedAssetRow:
-- The newest asset in [:range_start, :range_end), a group_date range; seeks the
-- timeline group index.
{page_cte(in_range('rae'), lin_range(), DESC, 'LIMIT 1')}
{BODY}""",
    f"""mergedAssetFavoriteCover{RANGE_ARGS} AS MergedAssetRow:
-- The newest favorite in [:range_start, :range_end); the literal is_favorite
-- filter lets it seek the partial favorites index.
{page_cte(in_range('rae') + "\n\t\tAND rae.is_favorite = 1", lin_range() + "\n\tAND lae.is_favorite = 1", DESC, 'LIMIT 1')}
{BODY}""",
]

open(path, "w").write(head + "\n".join(queries) + "\n" + tail)
