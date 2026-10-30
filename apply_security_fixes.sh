#!/usr/bin/env bash
#
# apply_security_fixes.sh - Apply security fixes the UN1CA sm7125 kernel tree
# does not have yet.
#
# Run it from the top of the kernel tree:
#
#     ./apply_security_fixes.sh             # apply the fixes
#     ./apply_security_fixes.sh --status    # which ones are in?
#     ./apply_security_fixes.sh --revert    # take them out again
#
# Each fix is a 4.14 backport of an upstream commit, embedded at the end of
# this script. A fix the tree already carries itself (e.g. after a `git pull`
# brought in UN1CA's or OpenELA's backport) is detected and skipped.
#
# The changes stay in the working tree until --revert. build_kernel.sh builds
# the tree as it is; build_all.sh applies, builds and reverts in one go.
#
# Fixes:
#   dirtyfrag   CVE-2026-43284 (Dirty Frag): ESP input decrypts in place over
#               page-cache pages spliced into a UDP socket.
#               Upstream: f4c50a4034e6 "xfrm: esp: avoid in-place decrypt on
#               shared skb frags". 4.14 has no MSG_SPLICE_PAGES; its UDP
#               splice path is ip_append_page(), which gets the marking.
#   fragnesia   CVE-2026-46300 (Fragnesia): the shared-frag marker that
#               dirtyfrag relies on is lost when frags move between skbs.
#               Upstream: f84eca581739 "net: skbuff: preserve shared-frag
#               marker during coalescing" and 48f6a5356a33 "net: skbuff:
#               propagate shared-frag marker through frag-transfer helpers"
#               (the helpers 4.14 has; it predates skb_gro_receive_list() and
#               tcp_clone_payload()).
#   (CVE-2026-43500, Dirty Frag's RxRPC half, does not apply: the code is
#   from 2023 and CONFIG_AF_RXRPC is off. GhostLock, CVE-2026-43499, is
#   already fixed in the tree.)
#
# Options:
#   --status      Print the state of each fix; exit 0 if all are in, 3 if not
#   --revert      Remove the fixes this script applied
#   -h, --help    Show this help

set -euo pipefail

ROOT_DIR="$PWD"

FIXES=(dirtyfrag fragnesia)

APPLIED_NOW=()          # fixes applied by this run

log() {
    echo
    echo "==============================================="
    echo "$*"
    echo "==============================================="
}

die() {
    echo >&2
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    sed -n '3,/^set -euo pipefail$/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
}

check_kernel_tree() {
    [ -f "$ROOT_DIR/build.sh" ] &&
        [ -f "$ROOT_DIR/arch/arm64/configs/vendor/atoll-sec-perf_defconfig" ] ||
        die "$ROOT_DIR is not the sm7125 kernel tree; run this from its top directory"
    command -v git >/dev/null 2>&1 ||
        die "git is missing; install it from the Debian repositories with:
    sudo apt install git"
    git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        die "$ROOT_DIR is not a git checkout (needed to apply and revert the fixes)"
}

# Body of C function <name> in <file>, from its definition line to the
# closing brace in column 0.
function_body() {
    awk -v name="$2" '
        !found && $0 ~ "^[a-z].*[ *]" name "\\(" { found = 1 }
        found { print }
        found && /^}/ { exit }
    ' "$ROOT_DIR/$1"
}

# Whether the tree fixes <fix> on its own (without our patch).
fixed_in_tree() {
    case "$1" in
        dirtyfrag)
            function_body net/ipv4/esp4.c esp_input | grep -q skb_has_shared_frag ;;
        fragnesia)
            function_body net/core/skbuff.c skb_try_coalesce | grep -q SHARED_FRAG ;;
    esac
}

fix_patch() {
    sed -n "/^__FIX_$1_BEGIN__\$/,/^__FIX_$1_END__\$/{//!p}" "${BASH_SOURCE[0]}"
}

fix_files() {
    fix_patch "$1" | sed -n 's|^diff --git a/\(.*\) b/.*|\1|p'
}

# "applied", "in-tree", "unapplied" or "conflict".
fix_state() {
    if fix_patch "$1" | git -C "$ROOT_DIR" apply --reverse --check - 2>/dev/null; then
        echo applied
    elif fixed_in_tree "$1"; then
        echo in-tree
    elif fix_patch "$1" | git -C "$ROOT_DIR" apply --check - 2>/dev/null; then
        echo unapplied
    else
        echo conflict
    fi
}

# Apply or revert (-R) <fix>, falling back to a 3-way merge when the context
# moved. A 3-way merge stages its result; it is unstaged again so the change
# lives in the working tree only.
patch_tree() {
    local fix="$1" files
    shift
    mapfile -t files < <(fix_files "$fix")
    if fix_patch "$fix" | git -C "$ROOT_DIR" apply "$@" - 2>/dev/null; then
        return 0
    fi
    git -C "$ROOT_DIR" diff --cached --quiet -- "${files[@]}" || return 1
    if fix_patch "$fix" | git -C "$ROOT_DIR" apply --3way "$@" - >/dev/null 2>&1 &&
       git -C "$ROOT_DIR" diff --quiet --diff-filter=U; then
        git -C "$ROOT_DIR" reset -q -- "${files[@]}"
        return 0
    fi
    git -C "$ROOT_DIR" reset -q -- "${files[@]}"
    return 1
}

show_status() {
    local fix state all=0
    for fix in "${FIXES[@]}"; do
        state="$(fix_state "$fix")"
        printf '%-10s %s\n' "$fix" "$state"
        case "$state" in applied|in-tree) ;; *) all=3 ;; esac
    done
    exit "$all"
}

apply_fixes() {
    log "Applying security fixes"
    local fix
    for fix in "${FIXES[@]}"; do
        case "$(fix_state "$fix")" in
            applied) echo "$fix: already applied" ;;
            in-tree) echo "$fix: the tree has its own fix; skipped" ;;
            *)
                patch_tree "$fix" ||
                    die "$fix no longer applies to this kernel tree ($(fix_files "$fix" | tr '\n' ' '))
    If the tree fixed it differently, update fixed_in_tree; otherwise
    update the patch at the end of this script."
                APPLIED_NOW+=("$fix")
                echo "$fix: applied"
                ;;
        esac
    done
}

revert_fixes() {
    log "Reverting security fixes"
    local fix i
    for ((i = ${#FIXES[@]} - 1; i >= 0; i--)); do
        fix="${FIXES[i]}"
        case "$(fix_state "$fix")" in
            applied)
                patch_tree "$fix" --reverse ||
                    die "$fix could not be reverted; restore with git checkout: $(fix_files "$fix" | tr '\n' ' ')"
                echo "$fix: reverted"
                ;;
            in-tree) echo "$fix: part of the tree; left alone" ;;
            unapplied) echo "$fix: not applied" ;;
            conflict)
                die "the files of $fix changed since it was applied; check them with
    git diff -- $(fix_files "$fix" | tr '\n' ' ')"
                ;;
        esac
    done
}

# A failed or interrupted run takes out the fixes it applied itself.
on_exit() {
    local status=$? i
    if [ "$status" -ne 0 ] && [ ${#APPLIED_NOW[@]} -gt 0 ]; then
        set +e
        echo "Undoing the fixes applied by this run" >&2
        for ((i = ${#APPLIED_NOW[@]} - 1; i >= 0; i--)); do
            patch_tree "${APPLIED_NOW[i]}" --reverse ||
                echo "WARNING: could not revert ${APPLIED_NOW[i]}" >&2
        done
    fi
    exit "$status"
}

action=apply
while [ $# -gt 0 ]; do
    case "$1" in
        --status) action=status ;;
        --revert) action=revert ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done

check_kernel_tree
case "$action" in
    status) show_status ;;
    revert) revert_fixes; exit 0 ;;
esac

trap on_exit EXIT
trap 'exit 130' INT TERM
apply_fixes
APPLIED_NOW=()
log "Security fixes applied; build with ./build_kernel.sh, undo with $0 --revert"
exit 0

# 4.14 backports (git diff format), one block per fix.
: <<'__FIXES_END__'
__FIX_dirtyfrag_BEGIN__
diff --git a/net/ipv4/esp4.c b/net/ipv4/esp4.c
index 79fa2d7852ef..54193fffd933 100755
--- a/net/ipv4/esp4.c
+++ b/net/ipv4/esp4.c
@@ -710,7 +710,8 @@ static int esp_input(struct xfrm_state *x, struct sk_buff *skb)
 			nfrags = 1;
 
 			goto skip_cow;
-		} else if (!skb_has_frag_list(skb)) {
+		} else if (!skb_has_frag_list(skb) &&
+			   !skb_has_shared_frag(skb)) {
 			nfrags = skb_shinfo(skb)->nr_frags;
 			nfrags++;
 
diff --git a/net/ipv6/esp6.c b/net/ipv6/esp6.c
index 25c12d0ccd28..5bc3993be06f 100755
--- a/net/ipv6/esp6.c
+++ b/net/ipv6/esp6.c
@@ -622,7 +622,8 @@ static int esp6_input(struct xfrm_state *x, struct sk_buff *skb)
 			nfrags = 1;
 
 			goto skip_cow;
-		} else if (!skb_has_frag_list(skb)) {
+		} else if (!skb_has_frag_list(skb) &&
+			   !skb_has_shared_frag(skb)) {
 			nfrags = skb_shinfo(skb)->nr_frags;
 			nfrags++;
 
diff --git a/net/ipv4/ip_output.c b/net/ipv4/ip_output.c
index 0cdb998c17ef..556face5d5ca 100755
--- a/net/ipv4/ip_output.c
+++ b/net/ipv4/ip_output.c
@@ -1306,6 +1306,8 @@ ssize_t	ip_append_page(struct sock *sk, struct flowi4 *fl4, struct page *page,
 			err = -EMSGSIZE;
 			goto error;
 		}
+		if (!(flags & MSG_NO_SHARED_FRAGS))
+			skb_shinfo(skb)->tx_flags |= SKBTX_SHARED_FRAG;
 
 		if (skb->ip_summed == CHECKSUM_NONE) {
 			__wsum csum;
__FIX_dirtyfrag_END__
__FIX_fragnesia_BEGIN__
diff --git a/net/core/skbuff.c b/net/core/skbuff.c
index 4dff86beb55d..c192f629e4b1 100755
--- a/net/core/skbuff.c
+++ b/net/core/skbuff.c
@@ -1469,6 +1469,8 @@ struct sk_buff *__pskb_copy_fclone(struct sk_buff *skb, int headroom,
 			skb_frag_ref(skb, i);
 		}
 		skb_shinfo(n)->nr_frags = i;
+		skb_shinfo(n)->tx_flags |= skb_shinfo(skb)->tx_flags &
+					    SKBTX_SHARED_FRAG;
 	}
 
 	if (skb_has_frag_list(skb)) {
@@ -3286,6 +3288,9 @@ onlymerged:
 	tgt->ip_summed = CHECKSUM_PARTIAL;
 	skb->ip_summed = CHECKSUM_PARTIAL;
 
+	skb_shinfo(tgt)->tx_flags |= skb_shinfo(skb)->tx_flags &
+				      SKBTX_SHARED_FRAG;
+
 	/* Yak, is it really working this way? Some helper please? */
 	skb->len -= shiftlen;
 	skb->data_len -= shiftlen;
@@ -3781,7 +3786,8 @@ normal:
 		skb_copy_from_linear_data_offset(head_skb, offset,
 						 skb_put(nskb, hsize), hsize);
 
-		skb_shinfo(nskb)->tx_flags |= skb_shinfo(head_skb)->tx_flags &
+		skb_shinfo(nskb)->tx_flags |= (skb_shinfo(head_skb)->tx_flags |
+					       skb_shinfo(frag_skb)->tx_flags) &
 					      SKBTX_SHARED_FRAG;
 
 		while (pos < offset + len) {
@@ -3793,6 +3799,10 @@ normal:
 				frag = skb_shinfo(list_skb)->frags;
 				frag_skb = list_skb;
 
+				skb_shinfo(nskb)->tx_flags |=
+					skb_shinfo(frag_skb)->tx_flags &
+					SKBTX_SHARED_FRAG;
+
 				BUG_ON(!nfrags);
 
 				list_skb = list_skb->next;
@@ -4006,10 +4016,12 @@ done:
 	p->data_len += len;
 	p->truesize += delta_truesize;
 	p->len += len;
+	skb_shinfo(p)->tx_flags |= skbinfo->tx_flags & SKBTX_SHARED_FRAG;
 	if (lp != p) {
 		lp->data_len += len;
 		lp->truesize += delta_truesize;
 		lp->len += len;
+		skb_shinfo(lp)->tx_flags |= skbinfo->tx_flags & SKBTX_SHARED_FRAG;
 	}
 	NAPI_GRO_CB(skb)->same_flow = 1;
 	return 0;
@@ -4953,6 +4965,9 @@ bool skb_try_coalesce(struct sk_buff *to, struct sk_buff *from,
 	       skb_shinfo(from)->frags,
 	       skb_shinfo(from)->nr_frags * sizeof(skb_frag_t));
 	skb_shinfo(to)->nr_frags += skb_shinfo(from)->nr_frags;
+	if (skb_shinfo(from)->nr_frags)
+		skb_shinfo(to)->tx_flags |= skb_shinfo(from)->tx_flags &
+					     SKBTX_SHARED_FRAG;
 
 	if (!skb_cloned(from))
 		skb_shinfo(from)->nr_frags = 0;
__FIX_fragnesia_END__
__FIXES_END__
