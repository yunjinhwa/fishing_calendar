"""Offline checks for strict identity and section-local public-photo evidence."""

import unittest

if __package__:
    from . import collect_nifs_fish_photos as collector
else:
    import collect_nifs_fish_photos as collector


BADGE = (
    '<img src="/cmmn/images/img_opentype01.png" '
    'alt="공공누리 1유형:출처표시 (상업적 이용 및 변경 가능)">'
)


def section(name="갈치", science="Trichiurus japonicus", badge=BADGE, image=None):
    if image is None:
        image = (
            '<img class="md-img-sel" src="/cmmn/images/MF123_photo.png" '
            f'alt="{name}">'
        )
    return (
        '<div class="modal-content" role="dialog">'
        f'<div class="head">{badge}<h2>{name}</h2></div>'
        f'<div class="cont">{image}<table><tbody><tr>'
        f'<th scope="row">국명</th><td>{name}</td>'
        f'<th>학명</th><td>{science}</td>'
        '</tr></tbody></table></div></div>'
    )


def page(*sections, footer=""):
    return '<div id="tab-1">' + "".join(sections) + '</div>' + footer


class ParsePhotosTests(unittest.TestCase):
    def test_requires_explicit_section_local_type_one_badge(self):
        key = ("갈치", "Trichiurus japonicus")
        self.assertIn(key, collector.parse_photos(page(section())))
        invalid_badges = (
            "",
            BADGE.replace("img_opentype01", "img_opentype02"),
            BADGE.replace("상업적 이용 및 변경 가능", "출처표시"),
        )
        for badge in invalid_badges:
            with self.subTest(badge=badge):
                html = page(section(badge=badge), footer=BADGE)
                self.assertNotIn(key, collector.parse_photos(html))

    def test_only_matching_named_primary_fish_photo_is_accepted(self):
        key = ("갈치", "Trichiurus japonicus")
        valid = '<img class="md-img-sel" src="/cmmn/images/MF123_photo.png" alt="갈치">'
        invalid_images = (
            valid.replace("MF123_photo.png", "110009.jpg"),
            valid.replace('class="md-img-sel"', 'class="distribution-map"'),
            valid.replace('alt="갈치"', 'alt="갈치 이동사진"'),
            valid.replace("/cmmn/images/MF123_photo.png", "https://example.org/MF123_photo.png"),
        )
        for image in invalid_images:
            with self.subTest(image=image):
                self.assertNotIn(key, collector.parse_photos(page(section(image=image))))

    def test_identity_keeps_exact_name_and_scientific_name(self):
        expected = ("갈치", "Trichiurus japonicus")
        for name, science in (
            ("갈치", "Trichiurus lepturus"),
            ("먹갈치", "Trichiurus japonicus"),
            ("갈치", "trichiurus japonicus"),
        ):
            with self.subTest(name=name, science=science):
                photos = collector.parse_photos(page(section(name, science)))
                self.assertNotIn(expected, photos)
                self.assertIn((name, science), photos)

    def test_license_does_not_leak_between_sections(self):
        photos = collector.parse_photos(page(
            section(),
            section("고등어", "Scomber japonicus", badge=""),
        ))
        self.assertEqual(set(photos), {("갈치", "Trichiurus japonicus")})


if __name__ == "__main__":
    unittest.main()
