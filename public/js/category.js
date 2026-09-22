/**
 * Category Operations
 */

import * as LRR from "./mod/common.js";
import * as Server from "./mod/server.js";
import I18N from "i18n";

const Category = {};

Category.categories = [];

export function initializeAll() {

    Server.loadBookmarkCategoryId().then(_ => {
        Category.loadCategories();
    });

    // bind events to DOM
    $(document).on("change.category", "#category", Category.updateCategoryDetails);
    $(document).on("change.catname", "#catname", Category.saveCurrentCategoryDetails);
    $(document).on("change.catsearch", "#catsearch", Category.saveCurrentCategoryDetails);
    $(document).on("change.pinned", "#pinned", Category.saveCurrentCategoryDetails);
    $(document).on("change.bookmark-link", "#bookmark-link", Category.updateBookmarkLink);
    $(document).on("click.new-static", "#new-static", () => Category.addNewCategory(false));
    $(document).on("click.new-dynamic", "#new-dynamic", () => Category.addNewCategory(true));
    $(document).on("click.predicate-help", "#predicate-help", Category.predicateHelp);
    $(document).on("click.delete", "#delete", Category.deleteSelectedCategory);
    $(document).on("click.return", "#return", () => { window.location.href = new LRR.ApiURL("/"); });

};

Category.addNewCategory = function (isDynamic) {
    LRR.showPopUp({
        title: I18N.NewCategory,
        input: "text",
        inputPlaceholder: I18N.CategoryDefaultName,
        inputAttributes: {
            autocapitalize: "off",
        },
        showCancelButton: true,
        reverseButtons: true,
        inputValidator: (value) => {
            if (!value) {
                return I18N.MissingCatName;
            }
            return undefined;
        },
    }).then((result) => {
        if (result.isConfirmed) {
            // Initialize dynamic collections with a bogus search
            const searchtag = isDynamic ? "language:english" : "";

            // Make an API request to create category, search is empty -> static, otherwise dynamic
            Server.callAPI(`/api/categories?name=${result.value}&search=${searchtag}`, "PUT", `Category "${result.value}" created!`, "Error creating category:",
                (data) => {
                    // Reload categories and select the newly created ID
                    Category.loadCategories(data.category_id);
                },
            );
        }
    });
};

Category.loadCategories = function (selectedID) {
    fetch(new LRR.ApiURL("/api/categories"))
        .then((response) => response.json())
        .then((data) => {
            // Save data clientside for reference in later functions
            Category.categories = data;

            // Clear combobox and fill it again with categories from the API
            const catCombobox = document.getElementById("category");
            catCombobox.options.length = 0;
            // Add default
            catCombobox.options[catCombobox.options.length] = new Option("-- " + I18N.NoCategory + " --", "", true, false);

            // Add categories, select if the ID matches the optional argument
            data.forEach((c) => {
                const newOption = new Option(c.name, c.id, false, c.id === selectedID);
                catCombobox.options[catCombobox.options.length] = newOption;
            });
            // Update form with selected category details
            Category.updateCategoryDetails();
        })
        .catch((error) => LRR.showErrorToast(I18N.CategoryFetchError, error));
};

Category.updateCategoryDetails = function () {
    // Get selected category ID and find it in the reference array
    const categoryID = document.getElementById("category").value;
    const category = Category.categories.find((x) => x.id === categoryID);

    $("#staticcontent").hide();
    $("#bookmarklinkfield").hide();
    $("#dynamicplaceholder").show();

    $(".tag-options").hide();
    if (!category) return;
    $(".tag-options").show();

    document.getElementById("catname").value = category.name;
    document.getElementById("catsearch").value = category.search;
    document.getElementById("pinned").checked = Number(category.pinned) === 1;

    if (category.search === "") {
        // Show tankoubons and archives if static and check the matching IDs
        document.getElementById("bookmark-link").checked = (localStorage.getItem("bookmarkCategoryId") === category.id);
        $("#staticcontent").show();
        $("#bookmarklinkfield").show();
        $("#dynamicplaceholder").hide();
        $("#predicatefield").hide();

        // Sort tankoubon list alphabetically
        const tanklist = $("#tankoubonlist");
        tanklist.find("li").sort((a, b) => {
            const upA = $(a).find("label").text().toUpperCase();
            const upB = $(b).find("label").text().toUpperCase();
            return upA < upB ? -1 : (upA > upB ? 1 : 0);
        }).appendTo("#tankoubonlist");

        // Uncheck all
        $("#staticcontent input:checkbox").prop("checked", false);

        // CUSTOM FORK (feature/path-hash-id): 归档列表改为按页拉取。
        // 上游在这里直接对「服务端已渲染好的全部 <li>」排序并打勾；大库时
        // 服务端渲染耗时可达分钟级（撞心跳红线），所以改成前端分页。
        // 每拉完一页立即排序 + 打勾，保证分类里的归档即使排在第 500 条也能被勾上。
        Category.pageSize = undefined;
        Category.loadArchivePage(0, 0).then(() => Category.applyCategoryChecks());
    } else {
        // Show predicate field if dynamic
        $("#predicatefield").show();
        $("#bookmarklinkfield").hide();
    }
};

/**
 * CUSTOM FORK (feature/path-hash-id): 递归拉取一页归档并追加到 #archivelist。
 *
 * 与 batch.js 的 loadArchivePage 同一套路：服务端 /api/archives?start=N 已在
 * Archive.pm 里把分页下推到 Redis 的 ZRANGE，单页（默认 100 条）约 300ms。
 * 服务端不回传页大小，所以从第一页学到 pageSize；某页短于 pageSize 即到末尾。
 *
 * @param {number} start 本页起始偏移
 * @param {number} loaded 已追加的条数
 * @returns {Promise<number>} 全部拉完后的总条数
 */
Category.loadArchivePage = function (start, loaded) {
    return Server.callAPISilent(`/api/archives?start=${start}`, "GET").then((data) => {
        if (!Array.isArray(data) || data.length === 0) {
            Category.finishArchiveList(loaded);
            return loaded;
        }

        // 首页到达即移除模板里的「Loading archives...」占位符
        $("#arclist-placeholder").remove();

        data.forEach((archive) => {
            const escapedTitle = LRR.encodeHTML(archive.title) + (archive.isnew === "true" ? " 🆕" : "");
            const html = `<li><input type='checkbox' name='archive' id='${archive.arcid}' class='archive' onchange='Category.updateArchiveInCategory(this.id, this.checked)'><label for='${archive.arcid}'>${escapedTitle}</label></li>`;
            $("#archivelist").append(html);
        });

        // 每页拉完就对「当前已渲染的项」排序 + 打勾，避免最后一页才处理时
        // 前面页面的勾选状态被覆盖，也避免分类中靠后的归档漏勾。
        const arclist = $("#archivelist");
        arclist.find("li").sort((a, b) => {
            const upA = $(a).find("label").text().toUpperCase();
            const upB = $(b).find("label").text().toUpperCase();
            return upA < upB ? -1 : (upA > upB ? 1 : 0);
        }).appendTo("#archivelist");
        Category.applyCategoryChecks();

        if (Category.pageSize === undefined) Category.pageSize = data.length;
        if (data.length < Category.pageSize) {
            Category.finishArchiveList(loaded + data.length);
            return loaded + data.length;
        }

        return Category.loadArchivePage(start + data.length, loaded + data.length);
    }).catch((error) => {
        LRR.showErrorToast(I18N.ArchiveListLoadFailure, error);
        Category.finishArchiveList(loaded);
        return loaded;
    });
};

/**
 * CUSTOM FORK (feature/path-hash-id): 列表拉完（或失败）后的收尾。
 * 空库时给出与上游一致的提示文案，避免出现空白区域。
 */
Category.finishArchiveList = function (loaded) {
    $("#arclist-placeholder").remove();
    if (loaded === 0) {
        $("#archivelist").append(
            `<li style="font-style: italic;">${I18N.NoArchivesInLibrary}</li>`
        );
    }
};

/**
 * CUSTOM FORK (feature/path-hash-id): 给「当前已渲染」的归档打上分类勾选。
 *
 * 上游是一次性 forEach：找不到 checkbox 就静默跳过。分页后如果分类里某个归档
 * 还没被渲染出来，勾选会静默丢失（假成功）。所以这里改成每页渲染后都调用，
 * 找到才勾、找不到就等下一页——最终所有页拉完时全部命中。
 */
Category.applyCategoryChecks = function () {
    const categoryID = document.getElementById("category").value;
    const category = Category.categories.find((x) => x.id === categoryID);
    if (!category || !Array.isArray(category.archives)) return;

    category.archives.forEach((id) => {
        const checkbox = document.getElementById(id);

        if (checkbox != null && !checkbox.checked) {
            checkbox.checked = true;
            // Prepend matching <li> element to the top of the list (ew)
            checkbox.parentElement.parentElement.prepend(checkbox.parentElement);
        }
    });
};

Category.saveCurrentCategoryDetails = function () {
    // Get selected category ID
    const categoryID = document.getElementById("category").value;
    const catName = document.getElementById("catname").value;
    const searchtag = document.getElementById("catsearch").value;
    const pinned = document.getElementById("pinned").checked ? "1" : "0";

    Category.indicateSaving();

    // PUT update with name and search (search is empty if this is a static category)
    // Indicate saved and load categories are placed inside the API call to avoid race conditions.
    Server.callAPI(`/api/categories/${categoryID}?name=${catName}&search=${searchtag}&pinned=${pinned}`, "PUT", null, "Error updating category:",
        (data) => {
            Category.indicateSaved();
            Category.loadCategories(data.category_id);
        },
    );
};

Category.updateBookmarkLink = function () {
    const categoryID = document.getElementById("category").value;
    const isChecked = document.getElementById("bookmark-link").checked;
    const wasChecked = (localStorage.getItem("bookmarkCategoryId") === categoryID);

    if (!categoryID) {
        return;
    }

    Category.indicateSaving();

    if (isChecked && !wasChecked) {
        Server.callAPI(
            `/api/categories/bookmark_link/${categoryID}`,
            "PUT",
            null,
            I18N.BookmarkLinkError,
            () => {
                localStorage.setItem("bookmarkCategoryId", categoryID);
                Category.indicateSaved();
            }
        );
    } else if (!isChecked && wasChecked) {
        Server.callAPI(
            "/api/categories/bookmark_link",
            "DELETE",
            null,
            I18N.BookmarkUnlinkError,
            () => {
                localStorage.removeItem("bookmarkCategoryId");
                Category.indicateSaved();
            }
        );
    } else {
        Category.indicateSaved();
    }
};

export function updateArchiveInCategory(id, checked) {
    const categoryID = document.getElementById("category").value;
    Category.indicateSaving();
    // PUT/DELETE api/categories/catID/archiveID
    Server.callAPI(`/api/categories/${categoryID}/${id}`, checked ? "PUT" : "DELETE", null, I18N.CategoryEditError,
        () => {
            // Reload categories and select the archive list properly
            Category.indicateSaved();
            Category.loadCategories(categoryID);
        },
    );
};

Category.deleteSelectedCategory = function () {
    const categoryID = document.getElementById("category").value;
    LRR.showPopUp({
        text: I18N.CategoryDeleteConfirm,
        icon: "warning",
        showCancelButton: true,
        focusConfirm: false,
        confirmButtonText: I18N.ConfirmYes,
        reverseButtons: true,
        confirmButtonColor: "#d33",
    }).then((result) => {
        if (result.isConfirmed) {
            Server.callAPI(`/api/categories/${categoryID}`, "DELETE", I18N.CategoryDeleted, I18N.CategoryDeleteError,
                () => {
                    // Reload categories to show the archive list properly
                    Category.loadCategories();
                },
            );
        }
    });
};

Category.indicateSaving = function () {
    document.getElementById("status").innerHTML = `<i class="fas fa-spin fa-2x fa-compact-disc"></i> Saving your modifications...`;
};

Category.indicateSaved = function () {
    document.getElementById("status").innerHTML = `<i class="fas fa-2x fa-check-circle"></i> Saved!`;
};

Category.predicateHelp = function () {
    LRR.toast({
        toastId: "predicateHelp",
        heading: I18N.CategoryPredicateTitle,
        text: I18N.CategoryPredicateHelp,
        icon: "info",
        hideAfter: 20000,
    });
};
